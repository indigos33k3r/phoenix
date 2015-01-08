defmodule Phoenix.Channel do

  @moduledoc """
  Defines a Phoenix Channel.

  Channels provide a means for bidirectional communication from clients that
  integrates with the `Phoenix.PubSub` layer for soft-realtime functionality.

  ## Topics & Callbacks
  When clients join a channel, they do so by subscribing a topic.
  Topics are string idenitifiers in the `Phoenix.PubSub` layer that allow
  multiple processes to subscribe and broadcast messages about a give topic.
  Everytime you join a Channel, you need to choose which particular topic you
  want to listen to. The topic is just an identifier, but by convention it is
  often made of two parts: `"topic:subtopic"`. Using the `"topic:subtopic"`
  approach pairs nicely with the `Phoenix.Router.channel/3` macro to match
  topic patterns in your router to your channel handlers:

      socket "/ws", MyApp do
        channel "rooms:*", RoomChannel
      end

  Any topic coming into the router with the `"rooms:"` prefix, would dispatch
  to `MyApp.RoomChannel` in the above example. Topics can also be pattern
  matched in your channels' `join/3` callback to pluck out the scoped pattern:

      # handles the special `"lobby"` subtopic
      def join("rooms:lobby", _auth_message, socket) do
        {:ok, socket}
      end

      # handles any other subtopic as the room ID, ie `"rooms:12"`, `"rooms:34"`
      def join("rooms:" <> room_id, auth_message, socket) do
        {:ok, socket}
      end

  ### Authorization
  Clients must join a channel to send and receive PubSub events on that channel.
  Your channels must implement a `join/3` callback that authorizes the socket
  for the given channel. It is common for clients to send up authorization data,
  such as HMAC'd tokens for this purpose.

  To authorize a socket in `join/3`, return `{:ok, socket}`
  To refuse authorization in `join/3, return `{:error, socket, :some_reason}`


  ### Incoming Events
  After a client has successfully joined a channel, incoming events from the
  client are routed through the channel's `incoming/3` callbacks. Within these
  callbacks, you can perform any action. Typically you'll either foward a
  message out to all listeners with `Phoenix.Channel.broadcast/3`, or reply
  directly to the socket with `Phoenix.Channel.reply/3`.
  Incoming callbacks must return the `socket` to maintain ephemeral state.

  Here's an example of receiving an incoming `"new:msg"` event from a one client,
  and broadcasting the message to all topic subscribers for this socket.
  *Note*: `incoming/3` and `reply/3` both return the provided `socket`.

      def incoming("new:msg", %{"uid" => uid, "body" => body}, socket) do
        broadcast socket, "new:msg", %{uid: uid, body: body}
      end

  You can also send a reply directly to the socket:

      # client asks for their current rank, reply sent directly as new event
      def incoming("current:rank", socket) do
        reply socket, "current:rank", %{val: Game.get_rank(socket.assigns[:user])}
      end


  ### Outgoing Events

  When an event is broadcasted with `Phoenix.Channel.broadcast/3`, each channel
  subscribers' `outgoing/3` callback is triggered where the event can be
  replayed as is, or customized on a socket by socket basis to append extra
  information, or conditionall filter the message from being delivered.

      def incoming("new:msg", %{"uid" => uid, "body" => body}, socket) do
        broadcast socket, "new:msg", %{uid: uid, body: body}
      end

      # for every socket subscribing on this channel, append an `is_editable`
      # value for client metadata
      def outgoing("new:msg", msg, socket) do
        reply socket, "new:msg", Dict.merge(msg,
          is_editable: User.can_edit_message?(socket.assigns[:user], msg)
        )
      end

      # do not send broadcasted `"user:joined"` events if this socket's user
      # is ignoring the user who joined
      def outgoing("user:joined", msg, socket) do
        if User.ignoring?(socket.assigns[:user], msg.user_id do
          socket
        else
          reply socket, "user:joined", msg
        end
      end

   By default, unhandled outgoing events are forwarded to each client as a reply,
   but you'll need to define the catch-all clause yourself once you define an
   `outgoing/3` clause.

  """

  use Behaviour
  alias Phoenix.PubSub
  alias Phoenix.Socket
  alias Phoenix.Socket.Message

  defcallback join(topic :: binary, auth_msg :: map, Socket.t) :: {:ok, Socket.t} |
                                                                  {:error, Socket.t, reason :: term}

  defcallback leave(message :: map, Socket.t) :: Socket.t

  defcallback incoming(topic :: binary, message :: map, Socket.t) :: Socket.t

  defcallback outgoing(topic :: binary, message :: map, Socket.t) :: Socket.t

  defmacro __using__(_options) do
    quote do
      @behaviour unquote(__MODULE__)
      import unquote(__MODULE__)
      import Phoenix.Socket

      def leave(message, socket), do: socket
      def outgoing(event, message, socket) do
        reply(socket, event, message)
        socket
      end
      defoverridable leave: 2, outgoing: 3
    end
  end


  # TODO: Move this to pubsub
  @doc """
  Subscribes socket to given topic
  Returns `%Phoenix.Socket{}`
  """
  def subscribe(pid, topic) when is_pid(pid) do
    PubSub.subscribe(pid, topic)
  end
  def subscribe(socket, topic) do
    if !Socket.authorized?(socket, topic) do
      PubSub.subscribe(socket.pid, topic)
      Socket.authorize(socket, topic)
    else
      socket
    end
  end

  @doc """
  Unsubscribes socket from given topic
  Returns `%Phoenix.Socket{}`
  """
  def unsubscribe(pid, topic) when is_pid(pid) do
    PubSub.unsubscribe(pid, topic)
  end
  def unsubscribe(socket, topic) do
    PubSub.unsubscribe(socket.pid, topic)
    Socket.deauthorize(socket)
  end

  @doc """
  Broadcast event, serializable as JSON to channel

  ## Examples

      iex> Channel.broadcast "rooms:global", "new:message", %{id: 1, content: "hello"}
      :ok
      iex> Channel.broadcast socket, "new:message", %{id: 1, content: "hello"}
      :ok

  """
  def broadcast(topic, event, message) when is_binary(topic) do
    broadcast_from :global, topic, event, message
  end

  def broadcast(socket = %Socket{}, event, message) do
    broadcast_from :global, socket.topic, event, message
  end

  @doc """
  Broadcast event from pid, serializable as JSON to channel
  The broadcasting socket `from`, does not receive the published message.
  The event's message must be a map serializable as JSON.

  ## Examples

      iex> Channel.broadcast_from self, "rooms:global", "new:message", %{id: 1, content: "hello"}
      :ok

  """
  def broadcast_from(socket = %Socket{}, event, message) do
    broadcast_from(socket.pid, socket.topic, event, message)
  end
  def broadcast_from(from, topic, event, message) when is_map(message) do
    PubSub.create(topic)
    PubSub.broadcast_from from, topic, {:socket_broadcast, %Message{
      topic: topic,
      event: event,
      payload: message
    }}
  end
  def broadcast_from(_, _, _, _), do: raise_invalid_message

  @doc """
  Sends Dict, JSON serializable message to socket
  """
  def reply(socket, event, message) when is_map(message) do
    send socket.pid, {:socket_reply, %Message{
      topic: socket.topic,
      event: event,
      payload: message
    }}
    socket
  end
  def reply(_, _, _), do: raise_invalid_message

  @doc """
  Terminates socket connection, including all multiplexed channels
  """
  def terminate(socket), do: send(socket.pid, :shutdown)

  @doc """
  Hibernates socket connection
  """
  def hibernate(socket), do: send(socket.pid, :hibernate)

  defp raise_invalid_message, do: raise "Message argument must be a map"
end
