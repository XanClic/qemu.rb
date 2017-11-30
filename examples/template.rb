#!/usr/bin/ruby

require (File.realpath(File.dirname(__FILE__)) + '/../qemu.rb')


begin

vm = VM.new('qemu-system-x86_64')

vm.qmp.verbosity = true

vm.qmp.quit()
vm.wait()

rescue Exception => e
    if vm
        begin
            puts vm.stderr.read_nonblock(1048576)
        rescue
        end
        begin
            puts vm.stdout.read_nonblock(1048576)
        rescue
        end
        vm.kill
    end

    raise e.inspect
end
