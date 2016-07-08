require 'rbnacl'

module CRDT
  # A pair of logical timestamp (Lamport clock, which is just a number) and peer ID (256-bit hex
  # string that uniquely identifies a particular device). A peer increments its timestamp on every
  # operation, so this pair uniquely identifies a particular object, e.g. an element in a list.
  # It also provides a total ordering that is consistent with causality: if operation A happened
  # before operation B, then A's ItemID is lower than B's ItemID. The ordering of concurrent
  # operations is deterministic but arbitrary.
  class ItemID < Struct.new(:logical_ts, :peer_id)
    include Comparable

    def <=>(other)
      return nil unless other.respond_to?(:logical_ts) && other.respond_to?(:peer_id)
      return +1 if self.logical_ts > other.logical_ts
      return -1 if self.logical_ts < other.logical_ts
      self.peer_id <=> other.peer_id
    end
  end

  # General representation of a CRDT modification operation.
  #
  # op_id:  ItemID of this operation (must be unique and monotonically increasing).
  # target: ItemID of the object being modified in this operation.
  # op:     The actual operation object (specific to a particular datatype).
  Operation = Struct.new(:op_id, :target, :op)

  SchemaUpdate = Struct.new(:op_id, :app_version, :app_schema, :op_schema)

  InitializeRecordField = Struct.new(:field_num)

  class Peer
    include Encoding

    # A message is the unit at which a peer broadcasts information to other peers.
    Message = Struct.new(:sender_id, :sender_seq_no, :offset, :timestamp, :operations, :encoded)

    # Pseudo-operation, used to signal that all operations within a message have been processed.
    MessageProcessed = Struct.new(:last_seq_no)

    attr_reader :logger

    # 256-bit hex string that uniquely identifies this peer.
    attr_reader :peer_id

    # Keeps track of the key facts that we know about our peers.
    attr_reader :peer_matrix

    # CRDT map of peer ID => ItemID of the character at the current cursor position at that peer.
    attr_reader :cursors

    # ItemID of the cursors field in the application schema
    attr_accessor :cursors_item_id

    # CRDT data structure (TODO generalise this)
    attr_reader :ordered_list

    # ItemID of the characters field in the application schema
    attr_accessor :characters_item_id

    # ItemID of application schema for operations that originate at this peer
    attr_accessor :default_schema_id

    # 128-bit hex string that identifies the server channel on which this peer broadcasts and
    # receives communication with other peers.
    attr_accessor :channel_id

    # Monotonically increasing number that keeps track of which messages in a channel have already
    # been received and processed by this peer, and which haven't.
    attr_accessor :channel_offset

    # 256-bit hex string containing the symmetric encryption key for messages in the channel, or nil
    # if the channel is not encrypted.
    attr_reader :secret_key

    # NaCl SimpleBox object for encrypting and decrypting using a symmetric key.
    attr_reader :secret_box

    # Array of Message objects containing the log of all changes to the document.
    attr_reader :message_log

    # Hash of peer ID => array of messages sent by that peer
    attr_reader :messages_by_sender


    # Loads a peer's state from a file with the specified file path, or the specified IO object.
    def self.load(file, options={})
      if file.is_a? String
        File.open(file, 'rb') {|io| Encoding.load(io, options) }
      else
        Encoding.load(file, options)
      end
    end

    # Initializes a new peer instance with default state. If no peer ID is given, it is assigned a
    # new random peer ID (256-bit hex string).
    def initialize(peer_id=nil, options={})
      @peer_id = peer_id || bin_to_hex(RbNaCl::Random.random_bytes(32))
      @peer_matrix = PeerMatrix.new(@peer_id)
      @cursors = Map.new(self)
      @ordered_list = OrderedList.new(self)
      @channel_offset = -1
      @message_log = []
      @messages_by_sender = {}
      @messages_to_send = []
      @logger = options[:logger] || lambda {|msg| }
      @send_buf = []
      @recv_buf = {} # map of sender_id => array of operations
      self.secret_key = options[:secret_key]

      if options[:channel_id]
        @channel_id = options[:channel_id]
      else
        @channel_id = bin_to_hex(RbNaCl::Random.random_bytes(16)) # TODO should be generated by server?
        self.secret_key ||= bin_to_hex(RbNaCl::Random.random_bytes(32))

        @default_schema_id = next_id
        send_operation(SchemaUpdate.new(@default_schema_id, '',
                                        CRDT::Encoding::APPLICATION_SCHEMA,
                                        CRDT::Encoding::APP_OPERATION_SCHEMA.to_s))

        @cursors_item_id = next_id
        send_operation(Operation.new(@cursors_item_id, @cursors_item_id,
                                     InitializeRecordField.new(0)))

        @characters_item_id = next_id
        send_operation(Operation.new(@characters_item_id, @characters_item_id,
                                     InitializeRecordField.new(1)))
      end
    end

    # Returns true if this peer has buffered information that should be broadcast to other peers.
    def anything_to_send?
      !@send_buf.empty?
    end

    # Generates a new unique ItemID for use within the CRDT.
    def next_id
      peer_matrix.next_logical_ts(peer_id)
    end

    # Called by the CRDT to enqueue an operation to be broadcast to other peers. Does not send the
    # operation immediately, just puts it in a buffer.
    def send_operation(operation)
      # Record causal dependencies of the operation before the operation itself
      @send_buf << peer_matrix.make_clock_update if peer_matrix.has_clock_update?
      @send_buf << operation
    end

    # Returns a message that should be sent to remote peers. Resets the buffer of pending
    # operations, so the same operations won't be returned again.
    def make_message
      @send_buf << peer_matrix.make_clock_update if peer_matrix.has_clock_update?

      message = Message.new(peer_id, peer_matrix.increment_sent_messages, nil, Time.now, @send_buf, nil)
      @send_buf = []
      message
    end

    # Receives a message from a remote peer. The operations will be applied immediately if they are
    # causally ready, or buffered until later if dependencies are missing.
    def process_message(message)
      if message.offset
        raise 'Non-monotonic channel offset' if message.offset <= channel_offset
        self.channel_offset = message.offset
      end

      if message.sender_id != peer_id
        @recv_buf[message.sender_id] ||= []
        @recv_buf[message.sender_id].concat(message.operations)
        @recv_buf[message.sender_id] << MessageProcessed.new(message.sender_seq_no)
        while apply_operations_if_ready; end
      end
    end

    def message_log_append(msg)
      expected = (messages_by_sender[msg.sender_id] || []).size + 1 # sender_seq_no starts counting at 1
      if msg.sender_seq_no != expected
        raise "Non-consecutive sequence number: #{msg.sender_seq_no} != #{expected} for peer #{msg.sender_id}"
      end
      messages_by_sender[msg.sender_id] ||= []
      messages_by_sender[msg.sender_id] << msg
      message_log << msg
    end

    # Returns an array of messages that should be sent to remote peers, including any messages that
    # were generated previously but have not yet been confirmed as successfully sent. Resets the
    # buffer of pending messages to send, so the same messages won't be returned again.
    def messages_to_send
      if anything_to_send?
        msg = make_message
        @messages_to_send << msg
        message_log_append(msg)
      end

      ret = @messages_to_send
      @messages_to_send = []
      ret
    end

    def cursor_id
      @cursors[peer_id]
    end

    def cursor_id=(new_cursor_id)
      @cursors[peer_id] = new_cursor_id
    end

    def secret_key=(new_secret_key)
      @secret_key = new_secret_key
      @secret_box = new_secret_key && RbNaCl::SimpleBox.from_secret_key(hex_to_bin(new_secret_key))
    end

    private

    # Called when the state of the peer has been reloaded from disk.
    def reload!
      # A SchemaUpdate operation that might have been generated in the initializer is redundant if
      # the peer was loaded from disk. Clear out the send buffer to avoid duplicating it. There must
      # be a nicer way of doing this...
      @send_buf.clear

      # Any logged messages that were pending (not yet successfully broadcast to other peers) at the
      # time the peer was shut down should be re-enqueued in the network buffer.
      @messages_to_send = (messages_by_sender[peer_id] || []).select {|msg| msg.offset.nil? }
    end

    # Called if the server complains that it does not know about some message that we had previously
    # sent to it (perhaps due to failover to a server that is not fully up-to-date). We re-send any
    # messages since the server's last known message in order to bring it up-to-date. NB. This will
    # only replay messages that originated on the local peer, because the client-server protocol
    # currently does not have a facility for backfilling other peers' mesages.
    def replay_messages(last_known)
      if peer_matrix.own_seq_no < last_known
        raise "Client amnesia: latest local seqNo=#{peer_matrix.own_seq_no}, server last known=#{last_known}"
      end

      logger.call "Re-sending messages from seqNo #{last_known} to #{peer_matrix.own_seq_no}"
      replay = messages_by_sender[peer_id][last_known..-1]
      @messages_to_send.concat(replay)
    end

    # Checks if there are any causally ready operations in the receive buffer that we can apply, and
    # if so, applies them. Returns false if nothing was applied, and returns true if something was
    # applied. Keep calling this method in a loop until it returns false, to ensure all ready
    # buffers are drained.
    #
    # TODO this implementation allows the operations within one message to be partially applied,
    # which could lead to weirdness if a ClockUpdate operation occurs somewhere in the middle of a
    # sequence of other operations. The dependency will only be acknowledged in a clock update after
    # the operations in the message have been fully processed, but in fact newly generated
    # operations may start depending on operations in the partially applied message, leading to
    # downstream errors. Better would be to check ahead of time that all causal dependencies in a
    # message are fully satisfied, and then apply all the operations in a message in one go.
    def apply_operations_if_ready
      ready_peer_id, ready_ops = @recv_buf.detect do |peer_id, ops|
        peer_matrix.causally_ready?(peer_id) && !ops.empty?
      end
      return false if ready_peer_id.nil?

      while ready_ops.size > 0
        operation = ready_ops.shift

        case operation
        when PeerMatrix::ClockUpdate
          peer_matrix.apply_clock_update(ready_peer_id, operation)

          # Applying the clock update might make the following operations causally non-ready, so we
          # stop processing operations from this peer and check again for causal readiness.
          return true

        when SchemaUpdate
          operation.op_id ||= peer_matrix.next_logical_ts(ready_peer_id)
          if @default_schema_id && @default_schema_id != operation.op_id
            raise 'Multiple schemas on the same channel are not yet supported'
          end
          @default_schema_id = operation.op_id

        when MessageProcessed
          peer_matrix.processed_incoming_msg(ready_peer_id, operation.last_seq_no)

        when Operation
          operation.op_id ||= peer_matrix.next_logical_ts(ready_peer_id)
          peer_matrix.seen_logical_ts(operation.op_id)

          # TODO route by operation.target
          case operation.op
          when InitializeRecordField
            case operation.op.field_num
            when 0 then @cursors_item_id    = operation.op_id
            when 1 then @characters_item_id = operation.op_id
            end
          when OrderedList::InsertOp, OrderedList::DeleteOp
            ordered_list.apply_operation(operation)
          when Map::PutOp, Map::WriteOp
            cursors.apply_operation(operation)
          end

        else
          raise "Unknown operation type: #{operation.inspect}"
        end
      end

      true # Finished this peer, now another peer's operations might be causally ready
    end
  end
end
