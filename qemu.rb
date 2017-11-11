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

    def initialize(*command_line)
        @this_vm = $vm_counter
        $vm_counter += 1

        @qmp_socket = UNIXServer.new('/tmp/qemu.rb-qmp-' + @this_vm.to_s)

        @child = Process.fork()
        if !@child
            Process.exec(*command_line, '-qmp', 'unix:/tmp/qemu.rb-qmp-' + @this_vm.to_s,
                                        '-accel', 'qtest', '-display', 'none')
        end

        @qmp_con = @qmp_socket.accept()
        @qmp = QMP.new(@qmp_con)
    end

    def qmp
        @qmp
    end

    def kill(signal='KILL')
        Process.kill(signal, @child) if @child
        @child = nil
        begin
            File.delete('/tmp/qemu.rb-qmp-' + @this_vm.to_s)
        rescue
        end
    end

    def wait()
        Process.wait(@child) if @child
        @child = nil
        begin
            File.delete('/tmp/qemu.rb-qmp-' + @this_vm.to_s)
        rescue
        end
    end
end
