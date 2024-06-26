#!/usr/bin/ruby

# qemu.rb: Management of QEMU VMs
# Copyright (C) 2017 Hanna Reitz
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


require 'json'
require 'shellwords'
require 'socket'
require (File.realpath(File.dirname(__FILE__)) + '/qmp.rb')


$qemu_input = ''


class VM
    $vm_counter = 0

    def initialize(*command_line, qtest: true, keep_stdin: true,
                   keep_stdout: false, keep_stderr: false, normal_vm: false,
                   serial: false, print_full_cmdline: false,
                   qsd: false, rsd: false, ssh: false, kvm: false,
                   pass_fds: {}, gdb: false, tcp_socks: false, machine: 'q35')
        @this_vm = "#{Process.pid}-#{$vm_counter}"
        $vm_counter += 1

        if normal_vm
            qtest = false
        else
            kvm = false
            ssh = false
        end

        if qsd || rsd
            kvm = false
            normal_vm = false
            qtest = false
            serial = false
            ssh = false
        end

        if gdb
            keep_stdin = true
            keep_stdout = true
            keep_stderr = true
        end

        @ssh_known_hosts = '/tmp/qemu.rb-known-hosts-' + @this_vm if ssh

        if tcp_socks
            @qmp_socket_port = 50413 + 0
            @qtest_socket_port = 50413 + 1
            @serial_socket_port = 50413 + 2

            @qmp_socket = TCPServer.new(@qmp_socket_port)
            @qtest_socket = TCPServer.new(@qtest_socket_port) if qtest
            @serial_socket = TCPServer.new(@serial_socket_port) if serial
        else
            @qmp_socket_fname = '/tmp/qemu.rb-qmp-' + @this_vm
            @qtest_socket_fname = '/tmp/qemu.rb-qtest-' + @this_vm if qtest
            @serial_socket_fname = '/tmp/qemu.rb-serial-' + @this_vm if serial

            @qmp_socket = UNIXServer.new(@qmp_socket_fname)
            @qtest_socket = UNIXServer.new(@qtest_socket_fname) if qtest
            @serial_socket = UNIXServer.new(@serial_socket_fname) if serial
        end

        c_stdin, @stdin = keep_stdin ? [nil, nil] : IO.pipe()
        @stdout, c_stdout = keep_stdout ? [nil, nil] : IO.pipe()
        @stderr, c_stderr = keep_stderr ? [nil, nil] : IO.pipe()

        command_line.map! do |arg|
            if arg.kind_of?(Hash)
                JSON.unparse(qmp_replace_underscores(arg))
            else
                arg
            end
        end

        if ssh.kind_of?(Integer)
            @ssh_port = ssh
        else
            @ssh_port = 2345
        end

        @child = Process.fork()
        if !@child
            accel_list = ['tcg']
            if qtest
                accel_list = ['qtest'] + accel_list
            elsif kvm
                accel_list = ['kvm'] + accel_list
            end

            if rsd
                chardev = {
                    id: 'char0',
                    backend: {
                        type: 'socket',
                    }
                }
                if tcp_socks
                    chardev[:backend][:data] = {
                        addr: {
                            type: 'inet',
                            host: '127.0.0.1',
                            port: @qmp_socket_port.to_s,
                        },
                    }
                else
                    chardev[:backend][:data] = {
                        addr: {
                            type: 'unix',
                            path: @qmp_socket_fname,
                        },
                    }
                end

                monitor = {
                    id: 'mon0',
                    chardev: chardev[:id],
                }

                add_args = ['--chardev', JSON.unparse(chardev),
                            '--monitor', JSON.unparse(monitor)]
            elsif qsd
                mon_arg = tcp_socks ? "host=127.0.0.1,port=#{@qmp_socket_port}" : "path=#{@qmp_socket_fname}"
                add_args = ['--chardev', "socket,id=mon0,#{mon_arg}",
                            '--monitor', 'mon0']
            else
                mon_arg = tcp_socks ? "host=127.0.0.1,port=#{@qmp_socket_port}" : "path=#{@qmp_socket_fname}"
                add_args = ['--chardev', "socket,id=mon0,#{mon_arg}",
                            '--mon', 'mon0,mode=control']
                if !(command_line & ['-M', '--machine']).empty?
                    add_args += ['--machine', "#{machine},accel=#{accel_list * ':'}"]
                end
            end
            add_args += ['-qtest', tcp_socks ? "tcp:127.0.0.1:#{@qtest_socket_port}" : "unix:#{@qtest_socket_fname}"] if qtest
            add_args += ['-display', 'none'] if !normal_vm && !qsd && !rsd
            add_args += ['-serial', tcp_socks ? "tcp:127.0.0.1:#{@serial_socket_port}" : "unix:#{@serial_socket_fname}"] if serial
            add_args += ['--netdev', "user,id=net,hostfwd=tcp:127.0.0.1:#{@ssh_port}-:22",
                         '--device', 'e1000,netdev=net'] if ssh

            # FIXME (something with the e1000e BIOS file)
            add_args += ['-net', 'none'] if !normal_vm && !qsd && !rsd

            if print_full_cmdline
                puts('$ ' + ((gdb ? ['gdb'] : []) + command_line + add_args).map { |arg| arg.shellescape } * ' ')
            end

            STDIN.reopen(c_stdin) unless keep_stdin
            STDOUT.reopen(c_stdout) unless keep_stdout
            STDERR.reopen(c_stderr) unless keep_stderr

            command_line.map! do |arg|
                if arg.include?('{FDSET:')
                    fname = arg.sub(/.*\{FDSET:([^}]*)\}.*/, '\1')
                    f = File.open(fname, 'r+')
                    f.close_on_exec = false
                    arg.sub(/(.*)\{FDSET:[^}]*\}(.*)/, "\\1#{f.fileno}\\2")
                else
                    arg
                end
            end

            if gdb
                Process.exec('gdb', '--eval-command', (['run'] + command_line[1..] + add_args).map { |arg| arg.shellescape } * ' ', command_line[0])
            else
                Process.exec(*command_line, *add_args)
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
            File.delete(@ssh_known_hosts) if @ssh_known_hosts
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

    def pid
        @child
    end

    def wait_ssh(login, pass)
        return false if !@ssh_known_hosts

        while !system("ssh-keyscan -T 1 -p #{@ssh_port} 127.0.0.1 2>/dev/null >#{@ssh_known_hosts.shellescape}")
            sleep(1)
        end

        @ssh_login = login
        @ssh_pass = pass

        return true
    end

    def ssh(cmd, background: false, capture: false)
        return nil if !@ssh_known_hosts || !File.file?(@ssh_known_hosts)

        args = ['sshpass', '-p', @ssh_pass,
                'ssh', '-p', @ssh_port.to_s,
                       '-o', "UserKnownHostsFile=#{@ssh_known_hosts}",
                       "#{@ssh_login}@127.0.0.1",
                cmd]

        if background
            if !fork
                Process.exec(*args)
                exit 1
            end
            true
        elsif capture
            `#{args.map { |a| a.shellescape } * ' '}`
        else
            system(args.map { |a| a.shellescape } * ' ')
        end
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
