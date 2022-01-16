require 'socket'
include Socket::Constants
require 'logger'

DEBUG = true
PORT = 25800

def program_loop(sockets)
  sockets
  mt = $env.mtime
  $l.debug("Script file last changed at #{mt}. Awaiting connection on port #{PORT}")
  loop do
    sockets.accept_all
    
    if $env.mtime != mt
      $l.error ['new control bridge profile found',mt,$env.mtime,'exiting']
      $env.update_process
      $l.error ['kill process',$cli.process_ids]
      Process.kill('HUP', $env.process_ids[0])
      exit
    end
  end
rescue => e
  $l.debug [e,e.backtrace]
  exit
ensure
  sockets.close if sockets
end



module SocketMethods
  attr_accessor :name, :ip, :port, :last, :http, :keep_reading, :delimiter, :pid, :script
end

class SocketServer < Socket

  attr_reader :port, :socks, :lsof
  
  def initialize(port)
    super(AF_INET, SOCK_STREAM, 0)
    @port = port
    @socks = []
    @lsof = RUBY_PLATFORM.include?('linux') ? 'lsof' : '/usr/sbin/lsof'
    @local_ip = Socket.ip_address_list.to_s[/ ((?!127)\d\d?\d?\.[0-9]+\.[0-9]+\.[0-9]+)/,1]
    connect('127.0.0.1', self, port)
    @t = Time.now
  end
  
  def accept_all
    ready = IO.select([self],nil,nil,10)
    if (Time.now - @t) > 30
      m = "#{$env.scli} writestate '#{$env.bp_names[0]}.script_launcher.running' 'YES'"
      $l.debug "sending running to  #{m}"
      
      `#{m}`
      @t = Time.now
    end
    return unless ready
    accept
    
  end
  
  def connect(addr, s, p)
    b = Socket.sockaddr_in(p, addr)
    s.setsockopt(:SOCKET, :REUSEADDR, true)
    s.bind(b)
    s.listen(5)
    @socket = s
  end
  
  def accept
    $l.debug ['accepting connections on', port]
    s,info = accept_nonblock
    s.extend SocketMethods
    s.ip = info.ip_address
    s.port = info.ip_port
    s.name = component_name(info.ip_port) || "#{info.ip_address}:#{info.ip_port}"
    pn = profile_name(s.name)
    $l.warn ['new connection from', s.name, 'on port', port]
    s.script = $env.profile_split(pn)
    `chmod +x #{s.script}`
    pr = Process.spawn("#{s.script}", :in => s, :out => s, :err => [:child, :out])
    Process.detach pr
    close_sock(s)
  end
  
  def component_name(port)
    pid = `#{@lsof} -i TCP:#{port} | grep avc`.match(/\s(\d+)\s/)
    @pid = pid
    pid && `ps -o command= -p #{pid[1]}`.chop.split('avc ')[1] 
  end
  
  def profile_name(component_name)
    s = %Q[source_component_name="#{component_name}" source_logical_component=]
    r = `grep -i '#{s}' '#{$env.rpm_path}userConfig.rpmConfig/serviceImplementation-serviceDefinitionOnly.xml'`.split("\n")
    m = r[0].match(/source_logical_component="([^"]+)"/)[1]
    #$l.debug [m, "grep -i '#{m}' '#{$env.profiles_path}'"]
    c = `grep -r '#{m}' '#{$env.profiles_path}'`.split("\n")[0].match(/componentProfiles\/\/?([^:]+):/)[1]
    $l.debug ['profile name',c]
    c
  end
  
  private
  
  def close_sock(sock)
    $l.debug(['closing',sock])
    socks.delete sock
    sock.close rescue nil
  end
  

end
  
class NonBlockSocket < Socket
  attr_reader :ip, :port
  
  include SocketMethods

  def initialize(ip, port)
    super(:INET, :STREAM, 0)
    @ip = ip
    @port = port
    connect(find_addr)
  end

  def waiting_writable(addr)
    IO.select(nil, [self], nil)
    connect_nonblock(addr)
  rescue Errno::EISCONN
    return self
  rescue IO::EINPROGRESSWaitWritable
    #log_savant 'waiting'
    sleep(0.5)
    retry
  end

  def connect(addr)
    connect_nonblock(addr)
  rescue IO::WaitWritable
    waiting_writable(addr)
  end

  def find_addr
    Socket.sockaddr_in(port, ip)
  end
end
  
  
class Environment

  attr_reader :profile_name, :profile_path, :script_path, :log_path, :home_path, \
              :profiles_path, :rpm_path, :lock_path, :bp_names, :process_ids, :scli

  def initialize
    @profile_name = 'script_launcher'
    if RUBY_PLATFORM.include?('linux')
      @home_path = '/home/RPM/'
      @rpm_path = "#{home_path}GNUstep/Library/ApplicationSupport/RacePointMedia/"
    else
      @home_path = '/Users/RPM/'
      @rpm_path = "#{home_path}Library/Application Support/RacePointMedia/"
    end
    @profiles_path = "#{rpm_path}userConfig.rpmConfig/componentProfiles/"
    @profile_path = "#{profiles_path}#{profile_name}.xml"
    @script_path =  "#{home_path}#{profile_name}"
    @log_path = "#{home_path}#{profile_name}.log"
    @scli = if RUBY_PLATFORM.include?('linux')  
      '/usr/local/bin/sclibridge'
    else
      '/Users/RPM/Applications/RacePointMedia/sclibridge'
    end
    
    @bp_names,@process_ids = update_process
    $l.debug([:names,@bp_names,:pids,@process_ids])
  end
  
  def profile_split(name)
    in_file = @profiles_path + name
    out_file = @home_path + name
    $l.debug "split #{in_file} to #{out_file}"
    File.open(in_file, 'r') do |input_file|
      output = input_file.read.split('#!/')[1]
      File.open(out_file, 'w') do |output_file|
        output_file.write output
      end
    end
    out_file
  end
  
  def mtime
    File.mtime(@profile_path)
  end
  
  def connection_info
    pattern = / po#{}rt="(\d+)".+proto#{}col="(\w+)"/
    `grep '<ip po#{}rt' "#{@profile_path}"`.match(pattern).captures
  end
  
  def update_process
    process_map(@profile_name)
  end

  def process_map(profile_name)
    names,pids = [],[]
    p = profile_name.split("_",2)
    s = ["manufacturer=",p[0].inspect," model=",p[1].inspect].join('')
    r = `grep -i '#{s}' '#{@rpm_path}userConfig.rpmConfig/serviceImplementation-serviceDefinitionOnly.xml'`
    r.scan(/ user_defined_name="([^"]+)"/).flatten.uniq.each_with_index do |avc,i|
      names[i] = avc
      pids[i] = `ps ax -o pid= -o command= | grep -v grep | grep 'avc #{avc}'`.to_i
      raise 'Savant System Still Loading avc process' unless pids[i] > 0
    end
    $l.debug [names,pids]
    [names,pids]
  rescue RuntimeError => e
    $l.error e
    sleep 5
    retry
  end

end


sock = SocketServer.new(PORT)
`touch /tmp/ss.log`

$l = Logger.new('/tmp/ss.log',1,1024000)
$l.level = Logger::WARN
$l.level = Logger::DEBUG if DEBUG

$env = Environment.new

$l.warn ['script started on',PORT]
$env.update_process
$l.debug($env.inspect)
$l.debug(Process.pid)
Process.daemon
program_loop(sock)
