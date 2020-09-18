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


require 'shellwords'
require 'socket'
require (File.realpath(File.dirname(__FILE__)) + '/qmp.rb')


$qemu_input = ''


class VM
    $vm_counter = 0

    def initialize(*command_line, qtest: true, keep_stdin: true,
                   keep_stdout: false, keep_stderr: false, normal_vm: false,
                   serial: false, print_full_cmdline: false)
        @this_vm = "#{Process.pid}-#{$vm_counter}"
        $vm_counter += 1

        if normal_vm
            qtest = false
        end

        @qmp_socket_fname = '/tmp/qemu.rb-qmp-' + @this_vm
        @qtest_socket_fname = '/tmp/qemu.rb-qtest-' + @this_vm if qtest
        @serial_socket_fname = '/tmp/qemu.rb-serial-' + @this_vm if serial

        @qmp_socket = UNIXServer.new(@qmp_socket_fname)
        @qtest_socket = UNIXServer.new(@qtest_socket_fname) if qtest
        @serial_socket = UNIXServer.new(@serial_socket_fname) if serial

        c_stdin, @stdin = keep_stdin ? [nil, nil] : IO.pipe()
        @stdout, c_stdout = keep_stdout ? [nil, nil] : IO.pipe()
        @stderr, c_stderr = keep_stderr ? [nil, nil] : IO.pipe()

        @child = Process.fork()
        if !@child
            add_args = ['-qmp', 'unix:' + @qmp_socket_fname]
            add_args += ['-M', 'q35,accel=qtest:tcg',
                         '-qtest', 'unix:' + @qtest_socket_fname] if qtest
            add_args += ['-M', 'q35,accel=tcg'] unless qtest || normal_vm
            add_args += ['-display', 'none'] unless normal_vm
            add_args += ['-serial', 'unix:' + @serial_socket_fname] if serial

            # FIXME (something with the e1000e BIOS file)
            add_args += ['-net', 'none'] unless normal_vm

            if print_full_cmdline
                puts('$ ' + (command_line + add_args).map { |arg| arg.shellescape } * ' ')
            end

            STDIN.reopen(c_stdin) unless keep_stdin
            STDOUT.reopen(c_stdout) unless keep_stdout
            STDERR.reopen(c_stderr) unless keep_stderr

            Process.exec(*command_line, *add_args)
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

    def serial
        if !@serial_socket
            return nil
        end

        if !@serial_con
            @serial_con = @serial_socket.accept()
        end

        @serial_con
    end

    def stdin
        @stdin
    end

    def stdout
        @stdout
    end

    def stderr
        @stderr
    end

    def cleanup()
        @stdout.close if @stdout
        @stderr.close if @stderr

        @child = nil
        begin
            File.delete(@qmp_socket_fname)
            File.delete(@qtest_socket_fname) if @qtest_socket_fname
            File.delete(@serial_socket_fname) if @serial_socket_fname
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


def qsystem(cmdline)
    $qemu_input += '$ ' + cmdline + $/
    system(cmdline)
end


def print_input
    at_exit do
        puts
        puts '--- INPUT SAMPLE ---'
        puts $qemu_input
        puts '--- END SAMPLE ---'
        puts
    end
end
