
require Logger

defmodule Telnet do

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Telnet.Worker, []),
      worker(Editor.Worker, []),
      #worker(Db.Worker, []),
    ]

    opts = [strategy: :one_for_one, name: Telnet.Supervisor]
    Supervisor.start_link(children, opts)
  end

end


defmodule Db.Snode do

  defstruct kind: :empty, id: "", kids: [], type: nil

  def new(kind, id, kids \\ %{}) do
    %Db.Snode{
      :kind => kind,
      :id => id,
      :kids => kids,
    }
  end


  def add(node, kid) when is_map(kid) do
    kids = Map.put(node.kids, kid.id, kid)
    %{node | :kids => kids}
  end

  
  def object(id) do new(:object, id) end
  def group(id) do new(:group, id) end

  def object(node, id) do node |> add(object(id)) end
  def group(node, id) do node |> add(group(id)) end

  
  #def add(node, kids) when is_list(kids) do
  #  Enum.map(kids, fn {k, v} ->
  #    kids = Map.add(node.kids, k, v)
  #    %{node | :kids => kids}
  #  end)
  #end

  def init() do
    group("")
    |> group("system")
    |> group("info" |> group("device"))
  end
end



defmodule Editor.Worker do

  use GenServer

  def init(init_arg) do
    {:ok, init_arg}
  end

  def start_link do
    _pid = GenServer.start_link(__MODULE__, 0, name: :editor)
  end

  def handle_call(:test, _from, n) do
    IO.inspect(n)
    if n == 3 do
      raise "boom"
    end
    {:reply, "blaa", n+1}
  end


end


defmodule Telnet.Editor do
  defstruct line: "", pos: 0

  def handle_char(editor, c) do
    IO.inspect(c)
    editor = case c do
      "\d" ->
        %{editor | :line => String.slice(editor.line, 0..-2)}
      _ ->
        %{editor | :line => editor.line <> c}
    end
    IO.puts(editor.line)
    editor
  end
end

defmodule Telnet.Session do
  defstruct echo: false, stop: false, width: 0, height: 0, editor: %Telnet.Editor{}, transport: nil, socket: nil
end


defmodule Telnet.Worker do

  def start_link do
    Logger.debug("start worker")
    opts = [
      port: 2300,
    ]

    {:ok, _} = :ranch.start_listener(:Telnet, :ranch_tcp, opts, Telnet.Handler, %Telnet.Session{})
  end

end


defmodule Telnet.Handler do

  @cmd_se    <<240>>
  #@cmd_nop   <<241>>
  #@cmd_dm    <<242>>
  #@cmd_brk   <<243>>
  #@cmd_ip    <<244>>
  #@cmd_ao    <<245>>
  #@cmd_ayt   <<246>>
  #@cmd_ec    <<247>>
  #@cmd_el    <<248>>
  #@cmd_ga    <<249>>
  @cmd_sb    <<250>>
  @cmd_will  <<251>>
  #@cmd_wont  <<252>>
  @cmd_do    <<253>>
  #@cmd_dont  <<254>>
  @cmd_iac   <<255>>

  @opt_suppress_go_ahead     <<3>>
  #@opt_status                <<5>>
  @opt_echo                  <<1>>
  #@opt_timing_mark           <<6>>
  #@opt_terminal_type         <<24>>
  @opt_window_size           <<31>>
  #@opt_terminal_speed        <<32>>
  #@opt_remote_flow_control   <<33>>
  #@opt_linemode              <<34>>
  #@opt_environment_variable  <<36>>

  defp srecv(session, n \\ 1) do
    case session.transport.recv(session.socket, n, 1000) do
      { :ok, data } -> data
      { :error, err } -> { :error, err }
    end
  end

  defp ssend(session, data) do
    session.transport.send(session.socket, data)
  end
  
  defp handle_do(session) do
    case srecv(session) do
      @opt_echo ->
        %{session | :echo => :true}
        session
      @opt_suppress_go_ahead -> 
        Logger.debug("> do suppress_go_ahead")
        session
    end
  end

  defp handle_will(session) do
    case srecv(session) do
      @opt_window_size ->
        Logger.debug("> will window_size")
        session
    end
  end

  defp handle_sb(session) do
    case srecv(session) do
      @opt_window_size -> 
        << width :: big-size(16), height :: big-size(16) >> = srecv(session, 4)
        Logger.debug "> window_size width: #{width}, height: #{height}"
        %{session | :width => width, :height => height}
    end
  end

  defp handle(session) do
    case srecv(session) do
      @cmd_iac ->
        case srecv(session) do
          @cmd_do -> handle_do(session)
          @cmd_will -> handle_will(session)
          @cmd_sb -> handle_sb(session)
          @cmd_se -> session
        end
      { :error, :timeout } -> session
      { :error, msg } ->
        Logger.warn("> " <> Atom.to_string(msg))
        %{session | :stop => :true}
      c ->
        IO.inspect(c)
        session = %{session | :editor => Telnet.Editor.handle_char(session.editor, c)}
        ssend(session, "\e[G")
        ssend(session, session.editor.line)
        ssend(session, "\e[K")
        session
    end
  end

  ## API
 
  def start_link(ref, transport, opts) do
    pid = spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  def init(ref, transport, session) do
    {:ok, socket } = :ranch.handshake(ref)
    session = %{session | :socket => socket}
    session = %{session | :transport => transport}

    Logger.debug("> accept")

    ssend(session, << @cmd_iac, @cmd_will, @opt_echo >>)
    ssend(session, << @cmd_iac, @cmd_will, @opt_suppress_go_ahead >>)
    ssend(session, << @cmd_iac, @cmd_do,   @opt_window_size >>)

    loop(session)
  end

  def loop(session) do
    session = handle(session)
    if not session.stop do
      loop(session)
    end
  end

end
