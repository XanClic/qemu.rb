#!/usr/bin/ruby

# qmp.rb: QMP communication over a socket
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

class QMPError < StandardError
    def initialize(object)
        @object = object
    end

    def object
        @object
    end

    def inspect
        'QMP error: ' + @object.inspect
    end
end

UNDERSCORE_METHODS = [
    :block_resize,
    :device_add,
    :device_del,
    :system_reset,
    :migrate_cancel,
]

def qmp_replace_underscores(val)
    if val.kind_of?(Hash)
        Hash[val.map { |k, v| [k.kind_of?(Symbol) ? k.to_s.tr('_', '-') : k, qmp_replace_underscores(v)] }]
    elsif val.kind_of?(Array)
        val.map { |v| qmp_replace_underscores(v) }
    else
        val
    end
end

class QMP
    def initialize(connection)
        @con = connection
        @events = []
        @deferred_events = []
        @verbose = false

        caps = self.recv()
        if !caps['QMP']
            raise 'Capability object does not contain "QMP" key'
        end

        if !caps['QMP']['capabilities']
            raise 'No capability list'
        end

        caps['QMP']['capabilities'].each do |cap|
            case cap
            when 'oob'
                # Ignore

            else
                raise "Unknown capability \"#{cap}\""
            end
        end

        self.exec('qmp_capabilities')
    end

    def verbosity
        @verbose
    end

    def verbosity=(v)
        @verbose = v
    end

    def send(object)
        raw = object.to_json()
        if @verbose
            if @verbose.kind_of?(String)
                puts("[#{@verbose}] #{raw}")
            else
                puts(raw)
            end
        end
        $qemu_input += raw + $/
        @con.send(raw, 0)
    end

    def recv()
        raw = @con.readline()
        if @verbose
            if @verbose.kind_of?(String)
                puts("[#{@verbose}] #{raw}")
            else
                puts(raw)
            end
        end
        JSON.parse(raw)
    end

    def recv_nonblock()
        raw = ''
        while true
            begin
                res = @con.read_nonblock(1)
            rescue
                break
            end
            if res.empty?
                break
            end
            raw += res
            if res == "\n"
                break
            end
        end
        if raw.empty?
            return nil
        end
        if @verbose
            if @verbose.kind_of?(String)
                puts("[#{@verbose}] #{raw}")
            else
                puts(raw)
            end
        end
        JSON.parse(raw)
    end

    def exec(cmd, args={})
        if cmd
            if args == {}
                self.send({ execute: cmd })
            else
                self.send({ execute: cmd, arguments: args })
            end
        end

        ret = {}
        while !ret['error'] && !ret['return']
            ret = self.recv()
            if ret['event']
                @events << ret
            end
        end

        if ret['error']
            raise QMPError.new(ret)
        else
            return ret['return']
        end
    end

    def cmp_hashes(ref, x)
        return false unless x.kind_of?(Hash)
        ref.each do |k, v|
            if v.kind_of?(Hash)
                return false unless self.cmp_hashes(v, x[k.to_s])
            else
                return false if x[k.to_s] != v
            end
        end
        return true
    end

    def event_wait(ref=nil, wait=true)
        if !ref
            ref = {}
        elsif ref.kind_of?(String)
            return self.event_wait({ event: ref }, wait)
        end

        event = @events.find { |ev| self.cmp_hashes(ref, ev) }
        if event
            @events.delete(event)
            return event
        end

        ret = {}
        first = true
        while first || wait
            if !wait
                ret = self.recv_nonblock()
                if !ret
                    break
                end
            else
                ret = self.recv()
            end
            if !ret['event']
                raise ('Event expected, got ' + ret.inspect)
            end
            return ret if self.cmp_hashes(ref, ret)
            @events << ret
            first = false
        end

        return nil
    end

    def clear_events()
        @events = []
    end

    def method_missing(method, *args)
        if !UNDERSCORE_METHODS.include?(method)
            method = method.to_s.tr('_', '-')
        else
            method = method.to_s
        end

        if args.empty?
            self.exec(method)
        else
            self.exec(method, qmp_replace_underscores(args[0]))
        end
    end

    # Helper function for run_job(); but may also be used by generic
    # event loops to replace run_job().
    #
    # (run_job() blocks until the job is dismissed.  If you want to
    #  use the generic job management it offers but still want to
    #  process other events concurrently, you may write your own event
    #  loop like so:
    #
    #    while [...]
    #        e = vm.qmp.event_wait
    #        vm.qmp.process_job_event(id, e, ...)
    #        [...your actions...]
    #    end
    # )
    #
    # @id: Block job ID
    # @event: Generic event
    # @auto_finalize: Whether the job was set to auto-finalize
    # @auto_dismiss: Whether the job was set to auto-dismiss
    #
    # Returns:
    # - nil when the event was not recognized as belonging to this
    #   job,
    # - false when the event belongs to this job, but the job
    #   continues to run,
    # - true when the job has been destroyed.
    #
    # Raises:
    # - A QMPError when the job has been aborted
    def process_job_event(id, event, job_state,
                          auto_finalize=true, auto_dismiss=false,
                          expect_error: false)
        return nil if event['event'] != 'JOB_STATUS_CHANGE'

        data = event['data']
        return nil if data['id'] != id

        case data['status']
        when 'ready'
            if !job_state[:send_complete]
                self.block_job_complete({ device: id })
                job_state[:send_complete] = true
            end

        when 'pending'
            self.job_finalize({ id: id }) unless auto_finalize

        when 'aborting'
            if !expect_error
                reason = self.query_jobs.find { |j| j['id'] == id }['error']
                raise QMPError.new({ 'error': reason })
            end

        when 'concluded'
            self.job_dismiss({ id: id }) unless auto_dismiss

        when 'null'
            return true
        end

        return false
    end

    # Runs process_job_event() in a loop and blocks until the job has
    # been completed.  Raises a QMPError if the job has been aborted.
    #
    # @id: Block job ID
    # @auto_finalize: Whether the job was set to auto-finalize
    # @auto_dismiss: Whether the job was set to auto-dismiss
    def run_job(id, auto_finalize=true, auto_dismiss=false, expect_error: false)
        job_state = {}

        while true
            e = self.event_wait

            ret = self.process_job_event(id, e, job_state,
                                         auto_finalize, auto_dismiss,
                                         expect_error: expect_error)
            break if ret

            @deferred_events << e if ret == nil
        end

        @events += @deferred_events
        @deferred_events = []
    end
end
