#!/usr/bin/ruby

# qemu.rb: Management of QEMU VMs
# Copyright (C) 2017 Max Reitz
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


require 'socket'
require (File.realpath(File.dirname(__FILE__)) + '/qmp.rb')


class VM
    $vm_counter = 0

    def initialize(*command_line, qtest: true)
        @this_vm = $vm_counter
        $vm_counter += 1

        @qmp_socket_fname = '/tmp/qemu.rb-qmp-' + @this_vm.to_s
        @qtest_socket_fname = '/tmp/qemu.rb-qtest-' + @this_vm.to_s if qtest

        @qmp_socket = UNIXServer.new(@qmp_socket_fname)
        @qtest_socket = UNIXServer.new(@qtest_socket_fname) if qtest

        @stdout, c_stdout = IO.pipe()
        @stderr, c_stderr = IO.pipe()

        @child = Process.fork()
        if !@child
            STDOUT.reopen(c_stdout)
            STDERR.reopen(c_stderr)
            if qtest
                Process.exec(*command_line, '-qmp', 'unix:' + @qmp_socket_fname,
                                            '-M', 'q35,accel=qtest:tcg', '-display', 'none',
                                            '-qtest', 'unix:' + @qtest_socket_fname)
            else
                Process.exec(*command_line, '-qmp', 'unix:' + @qmp_socket_fname,
                                            '-M', 'q35,accel=tcg', '-display', 'none')
            end
            exit 1
        end

        @qmp = nil
    end

    def qmp
        if !@qmp
            @qmp_con = @qmp_socket.accept()
            @qmp = QMP.new(@qmp_con)
        end

        @qmp
    end

    def qtest
        if !@qtest_socket
            return nil
        end

        if !@qtest_con
            @qtest_con = @qtest_socket.accept()
        end

        @qtest_con
    end

    def stdout
        @stdout
    end

    def stderr
        @stderr
    end

    def cleanup()
        @stdout.close
        @stderr.close

        @child = nil
        begin
            File.delete(@qmp_socket_fname)
            File.delete(@qtest_socket_fname) if @qtest_socket_fname
        rescue
        end
    end

    # If wait is not set, the caller has to call it (or .cleanup)
    # manually.
    def kill(signal='KILL', wait=true)
        Process.kill(signal, @child) if @child
        self.wait() if wait
    end

    def wait()
        Process.wait(@child) if @child
        self.cleanup()
    end
end
