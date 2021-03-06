require 'ffi'
require 'rbconfig'
require 'concurrent'
require 'logger'

module TonSdk
  module Interop
    extend FFI::Library

    logger = Logger.new(STDOUT)

    class TcStringData < FFI::Struct
      layout :content, :pointer,
        :len, :uint32

      def self.from_string(s)
        tcs = TcStringData.new
        bytes_count = s.unpack("C*").size
        ptr1 = FFI::MemoryPointer.new(:char, bytes_count)
        ptr1.put_bytes(0, s, 0, bytes_count)
        tcs[:content] = ptr1
        tcs[:len] = ptr1.size
        tcs
      end
    end

    class TcResponse < FFI::Struct
      layout :result_json, TcStringData,
        :error_json, TcStringData
    end

    DEFAULT_LIB_NAME = 'tonclient'
    base_lib_name2 = case RbConfig::CONFIG['host_os']
    when /linux/
      'linux'
    when /darwin/
      'darwin'
    when /mswin|mingw32|windows/
      'win32'
    else
      raise "unsupported OS: #{RbConfig::CONFIG['host_os']}"
    end

    lib_full_name = if !ENV['TON_CLIENT_NATIVE_LIB_NAME'].nil?
      ENV['TON_CLIENT_NATIVE_LIB_NAME']
    else
      fl_nm = "#{DEFAULT_LIB_NAME}.#{FFI::Platform::LIBSUFFIX}"
      File.join(File.expand_path(File.dirname(File.dirname(__dir__))), fl_nm)
    end

    ffi_lib(lib_full_name)




    #
    # in C
    #
    # enum tc_response_types_t {
    #   tc_response_success = 0,
    #   tc_response_error = 1,
    #   tc_response_nop = 2,
    #   tc_response_custom = 100,
    # };
    module TcResponseCodes
      SUCCESS = 0
      ERROR = 1
      NOP = 2
      CUSTOM = 100
    end


    #
    # in C
    #
    # tc_string_handle_t* tc_create_context(tc_string_data_t config);
    # void tc_destroy_context(uint32_t context);

    attach_function(:tc_create_context, [TcStringData.by_value], :pointer)
    attach_function(:tc_destroy_context, [:uint32], :void)


    #
    # in C
    #
    # tc_string_data_t tc_read_string(const tc_string_handle_t* string);
    # void tc_destroy_string(const tc_string_handle_t* string);

    attach_function(:tc_read_string, [:pointer], TcStringData.by_value)
    attach_function(:tc_destroy_string, [:pointer], :void)


    #
    # in C
    #
    # void tc_request(
    #   uint32_t context,
    #   tc_string_data_t function_name,
    #   tc_string_data_t function_params_json,
    #   uint32_t request_id,
    #   tc_response_handler_t response_handler);

    # typedef void (*tc_response_handler_t)(
    #   uint32_t request_id,
    #   tc_string_data_t params_json,
    #   uint32_t response_type,
    #   bool finished);

    callback(:tc_response_handler, [:uint32, TcStringData.by_value, :uint32, :bool], :void)
    attach_function(:tc_request, [:uint32, TcStringData.by_value, TcStringData.by_value, :uint32, :tc_response_handler], :void) # TODO possibly blocking: true

    #
    # in C
    #
    # tc_string_handle_t* tc_request_sync(
    #   uint32_t context,
    #   tc_string_data_t function_name,
    #   tc_string_data_t function_params_json);
    attach_function(:tc_request_sync, [:uint32, TcStringData.by_value, TcStringData.by_value], :pointer)



    @@request_counter = Concurrent::AtomicFixnum.new(1)

    def self.request_to_native_lib(
      ctx,
      function_name,
      function_params_json,
      custom_response_callback: nil,
      single_thread_only: true
    )

      function_name_tc_str = TcStringData.from_string(function_name)
      function_params_json_tc_str = TcStringData.from_string(function_params_json)

      sm = Concurrent::Semaphore.new(1)
      if single_thread_only == true
        sm.acquire()
      end

      # using @@request_counter here to pass a @@request_counter and handlers and then retrieve them
      # is probably isn't need in this Ruby implementation of SDK client
      # because they same affect can be achived without that, but in a block, in an easier way, that is.
      # therefore, @@request_counter is only used to send a request_counter to a server
      # and increment it for a next request, and for nothing else,
      # unlike in the other implementations of SDK clients

      self.tc_request(
        ctx,
        function_name_tc_str,
        function_params_json_tc_str,
        @@request_counter.value
      ) do |req_id, params_json, response_type, is_finished|

        tc_data_json_content = if params_json[:len] > 0
          res = params_json[:content].read_string(params_json[:len])
          JSON.parse(res)
        else
          ''
        end

        begin
          case response_type
          when TcResponseCodes::SUCCESS
            if block_given?
              yield NativeLibResponsetResult.new(result: tc_data_json_content)
            end
  
          when TcResponseCodes::ERROR
            if block_given?
              yield NativeLibResponsetResult.new(error: tc_data_json_content)
            end

          when TcResponseCodes::NOP
            nil

          when TcResponseCodes::CUSTOM
            custom_response_callback.call(tc_data_json_content) if !custom_response_callback.nil?

          else
            raise ArgumentError.new("unsupported response type: #{response_type}")
          end

        rescue => e
          logger.error(e)
        ensure
          if single_thread_only == true
            sm.release()
          end
        end
      end

      if single_thread_only == true
        sm.acquire()
      end

      @@request_counter.increment()
    end

    def self.request_to_native_lib_sync(ctx, function_name, function_params_json)
      function_name_tc_str = TcStringData.from_string(function_name)
      function_params_json_tc_str = TcStringData.from_string(function_params_json)
      self.tc_request_sync(ctx, function_name_tc_str, function_params_json_tc_str)
    end
  end
end