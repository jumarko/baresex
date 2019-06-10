defmodule Baresex.Worker do
  @moduledoc """
  Process that communicates with Baresip over TCP socket.
  """
  use Connection
  alias Baresex.{Protocol, Event}

  @events_with_accounts [Baresex.Event.Call, Baresex.Event.Register]

  defstruct sock: nil,
            host: "",
            port: 0,
            opts: [],
            timeout: 5000,
            messages: "",
            subscribers: %{}

  @doc """

  """
  def start_link(host \\ "127.0.0.1", port \\ 4444) do
    Connection.start_link(__MODULE__, {host, port, [], 5000}, name: __MODULE__)
  end

  @doc false
  def init({host, port, opts, timeout}) do
    s = %__MODULE__{host: to_charlist(host), port: port, opts: opts, timeout: timeout, sock: nil}
    {:connect, :init, s}
  end

  def connect(_, %{sock: nil, host: host, port: port} = s) do
    case Socket.connect("tcp://#{host}:#{port}") do
      {:ok, sock} ->
        receive_message(sock)
        {:ok, %{s | sock: sock}}

      {:error, _} ->
        {:backoff, 1000, s}
    end
  end

  def disconnect(info, %{sock: sock} = s) do
    :ok = Socket.close(sock)

    case info do
      {:close, from} ->
        Connection.reply(from, :ok)

      {:error, :closed} ->
        :error_logger.format("Connection closed~n", [])

      {:error, reason} ->
        reason = :inet.format_error(reason)
        :error_logger.format("Connection error: ~s~n", [reason])
    end

    {:connect, :reconnect, %{s | sock: nil}}
  end

  @doc """
  Subscribe
  """
  def subscribe(username, domain \\ "localhost") do
    Connection.call(__MODULE__, {:subscribe, {self(), "sip:#{username}@#{domain}"}})
  end

  def send(messages) do
    Connection.call(__MODULE__, {:send, messages})
  end

  @doc false
  def handle_call({:subscribe, {pid, aor}}, _, state) do
    subscribers = update_in(state.subscribers, [aor], &add_subscriber(&1, pid))
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @doc false
  def handle_call({:send, messages}, _, %{sock: sock} = s) do
    case send_messages(messages, sock) do
      :ok ->
        {:reply, :ok, s}

      {:error, _} = error ->
        {:disconnect, error, error, s}
    end
  end

  def handle_cast({:close, error}, s) do
    {:disconnect, error, s}
  end

  def handle_cast(:publish, state) do
    state = publish_event(state)
    {:noreply, state}
  end

  def handle_cast({:receive, msg}, state) do
    receive_message(state.sock)

    state =
      state
      |> process_message(msg)
      |> publish_event()

    {:noreply, state}
  end

  defp process_message(state, msg) do
    %{state | messages: state.messages <> msg}
  end

  defp publish_event(%__MODULE__{messages: ""} = state), do: state

  defp publish_event(%__MODULE__{subscribers: s} = state) when map_size(s) == 0,
    do: %{state | messages: ""}

  defp publish_event(state) do
    {message, tail} =
      state.messages
      |> Protocol.decode()

    event = Event.new(message)

    if subscribable?(event) do
      state.subscribers
      |> Map.get(event.account, [])
      |> send_event(event)
    end

    publish_next()
    put_in(state.messages, tail)
  end

  defp publish_next() do
    Connection.cast(self(), :publish)
  end

  defp send_messages([], _), do: :ok

  defp send_messages([message | t], sock) do
    msg = Protocol.encode(message)

    case Socket.Stream.send(sock, msg) do
      :ok -> send_messages(t, sock)
      {:error, _} = e -> e
    end
  end

  defp send_event([], _), do: :ok

  defp send_event([subscriber | t], event) do
    send(subscriber, event)
    send_event(t, event)
  end

  defp add_subscriber(nil, subscriber) do
    [subscriber]
  end

  defp add_subscriber(list, subscriber) do
    if Enum.member?(list, subscriber) do
      list
    else
      [subscriber | list]
    end
  end

  defp subscribable?(%{__struct__: struct}) when struct in @events_with_accounts, do: true
  defp subscribable?(_), do: false

  # Spawns an attendant process for (blocking) message receiving.
  defp receive_message(sock) do
    master = self()

    spawn(fn ->
      case Socket.Stream.recv(sock) do
        {:ok, msg} when msg != nil ->
          Connection.cast(master, {:receive, msg})

        {:ok, nil} ->
          Connection.cast(master, {:receive, ""})

        {:error, _} = e ->
          Connection.cast(master, {:close, e})
      end
    end)
  end
end
