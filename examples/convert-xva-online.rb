#!/usr/bin/ruby

require 'rubygems/package'
require 'shellwords'
require (File.realpath(File.dirname(__FILE__)) + '/../qemu.rb')


def help
    $stderr.puts("Usage: #{__FILE__} <XVA file> <disk directory> " +
                 "<output qcow2> [--write-zeroes]")
    $stderr.puts
    $stderr.puts('XVA file: Uncompressed XVA archive')
    $stderr.puts
    $stderr.puts('Disk directory: Directory inside the XVA archive ' +
                 'containing the disk')
    $stderr.puts('                (e.g. "Ref:42")')
    $stderr.puts
    $stderr.puts('Output qcow2: Output file to create')
    $stderr.puts('              (If the string starts with an {, it is ' +
                 'assumed to be a JSON')
    $stderr.puts('               blockdev description)')
    $stderr.puts
    $stderr.puts('--write-zeroes: Copy zeroes to the target')
    $stderr.puts
    $stderr.puts
    $stderr.puts('Example:')
    $stderr.puts("  #{__FILE__} xva.xva Ref:42 out.qcow2")

    $stderr.puts
    $stderr.puts
    $stderr.puts("Other usage: #{__FILE__} <XVA file>")
    $stderr.puts(' -- This lists all the disk directories in the file')
    $stderr.puts('    (and the minimum size of their corresponding disks)')

    exit
end


args = ARGV.to_a
xva = args.shift
dir_name = args.shift
output = args.shift
copy_zeroes = args.shift
if copy_zeroes && copy_zeroes != '--write-zeroes'
    $stderr.puts('Unexpected argument ' + copy_zeroes)
    args.each do |arg|
        $stderr.puts('Unexpected argument ' + arg)
    end
    exit 1
end
if !args.empty?
    args.each do |arg|
        $stderr.puts('Unexpected argument ' + arg)
    end
    exit 1
end

if !xva || xva.start_with?('-')
    help()
end

if output && output.start_with?('{')
    output = JSON.parse(output)
end

xva_io = File.open(xva)
xva_tar = Gem::Package::TarReader.new(xva_io)

disk_size = {}

parts = {}
max_index = 0
xva_tar.each do |entry|
    name = entry.full_name
    if !dir_name
        match = /^(Ref:\d+)\/(\d+)$/.match(name)
        if match
            disk = match[1]
            offset = match[2].to_i
            if !disk_size[disk]
                disk_size[disk] = offset + 1
            elsif disk_size[disk] <= offset
                disk_size[disk] = offset + 1
            end
        end
        next
    end

    match = /^#{dir_name}\/(\d+)$/.match(name)
    if entry.file? && match
        index = match[1].to_i
        parts[index] = xva_io.pos
        max_index = index if index > max_index
    end
end

if !dir_name
    if disk_size.empty?
        $stderr.puts('No disk found -- is this really an XVA file?')
        exit 1
    end
    disk_size.each do |disk, size|
        puts('%-10s  %i M' % [disk, size])
    end
    exit
end

if parts.empty?
    $stderr.puts('Disk not found.')
    exit 1
end

if output.kind_of?(String)
    if !system("qemu-img create -f qcow2 #{output.shellescape} #{max_index + 1}M")
        $stderr.puts('Failed to create output file')
        exit 1
    end
end

begin

vm = VM.new('qemu-system-x86_64')

puts 'Adding block devices...'

vm.qmp.blockdev_add({ node_name: 'input-xva',
                      driver: 'file',
                      filename: xva })

if output.kind_of?(String)
    vm.qmp.blockdev_add({ node_name: 'output-image',
                          driver: 'qcow2',
                          file: {
                              driver: 'file',
                              filename: output
                          } })
else
    output['node-name'] = 'output-image'
    vm.qmp.blockdev_add(output)
end

COPY_ZEROES = false

copy_index = 0
null_start = nil
0.upto(max_index) do |index|
    if parts[index]
        if null_start
            if COPY_ZEROES
                vm.qmp.blockdev_add({ node_name: "input-#{copy_index}",
                                      driver: 'null-co',
                                      size: (index - null_start) * 1048576,
                                      read_zeroes: true })

                vm.qmp.blockdev_add({ node_name: "output-#{copy_index}",
                                      driver: 'raw',
                                      offset: null_start * 1048576,
                                      size: (index - null_start) * 1048576,
                                      file: 'output-image' })

                copy_index += 1
            end
            null_start = nil
        end

        vm.qmp.blockdev_add({ node_name: "input-#{copy_index}",
                              driver: 'raw',
                              offset: parts[index],
                              size: 1048576,
                              file: 'input-xva' })

        vm.qmp.blockdev_add({ node_name: "output-#{copy_index}",
                              driver: 'raw',
                              offset: index * 1048576,
                              size: 1048576,
                              file: 'output-image' })

        copy_index += 1
    elsif !null_start
        null_start = index
    end
end

if null_start
    vm.qmp.blockdev_add({ node_name: "input-#{copy_index}",
                          driver: 'null-co',
                          size: (max_index + 1 - null_start) * 1048576,
                          read_zeroes: true })

    vm.qmp.blockdev_add({ node_name: "output-#{copy_index}",
                          driver: 'raw',
                          offset: null_start * 1048576,
                          size: (max_index + 1 - null_start) * 1048576,
                          file: 'output-image' })

    copy_index += 1
end

puts 'Starting block jobs...'

jobs_running = {}
copy_index.times do |i|
    jobs_running[i] = true
    vm.qmp.blockdev_backup({ job_id: "job-#{i}",
                             device: "input-#{i}",
                             target: "output-#{i}",
                             sync: 'full' })
end

jobs_completed = 0

while !jobs_running.empty?
    event = vm.qmp.event_wait('BLOCK_JOB_COMPLETED')
    jobs_running.delete(event['data']['device'][4..-1].to_i)

    jobs_completed += 1
    $stdout.write("#{'%.2f' % (jobs_completed * 100.0 / copy_index)} % of jobs completed\r")
    $stdout.flush
end

$stdout.puts

vm.qmp.quit
vm.wait

rescue QMPError => e
    vm.kill if vm
    raise e.inspect

rescue
    vm.kill if vm
    raise
end
