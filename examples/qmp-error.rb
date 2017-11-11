#!/usr/bin/ruby

require (File.realpath(File.dirname(__FILE__)) + '/../qemu.rb')

begin
    vm = VM.new('qemu-system-x86_64')

    vm.qmp.unknown_command()
    vm.quit()
    vm.wait()
rescue QMPError => e
    vm.kill(9)

    puts 'Received a QMP error when trying to execute unknown-command:'
    puts '  Class: ' + e.object['error']['class']
    puts '  Description: ' + e.object['error']['desc']
rescue
    vm.kill(9)
    raise
end
