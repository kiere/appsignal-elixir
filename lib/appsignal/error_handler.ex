defmodule Appsignal.ErrorHandler do
  @moduledoc """
  Error handler which sends all crash reports to the AppSignal backend.

  When you add `:appsignal` to your application's dependencies, this
  error logger will automatically be installed. All processes that are
  supervised, like GenServers, Tasks, Agents, Supervisored will be
  monitored for crashes. In the case of a crash, the AppSignal error
  handler collects error information and sends it to the backend.

  """

  alias Appsignal.{Backtrace, Error, Transaction}
  require Logger

  @transaction Application.get_env(:appsignal, :appsignal_transaction, Transaction)

  @spec handle_error(Transaction.t() | pid() | any(), any(), Exception.stacktrace(), map()) :: :ok
  def handle_error(pid_or_transaction, error, stack, conn \\ %{})

  def handle_error(pid, error, stack, conn) when is_pid(pid) do
    pid
    |> @transaction.lookup_or_create_transaction
    |> handle_error(error, stack, conn)
  end

  def handle_error(%Transaction{} = transaction, error, stack, conn) do
    set_error(transaction, error, stack)

    if @transaction.finish(transaction) == :sample do
      @transaction.set_request_metadata(transaction, conn)
    end

    @transaction.complete(transaction)
  end

  def handle_error(_transaction, _error, _stack, _conn), do: :ok

  @spec set_error(Transaction.t(), any(), Exception.stacktrace()) :: Transaction.t()
  def set_error(transaction, error, stack) do
    {exception, stacktrace} = Error.normalize(error, stack)
    {reason, message} = Error.metadata(exception)
    backtrace = Backtrace.from_stacktrace(stacktrace)

    @transaction.set_error(transaction, reason, message, backtrace)
  end

  def submit_transaction(transaction, reason, message, stack, metadata, conn \\ nil)

  def submit_transaction(transaction, reason, message, stack, metadata, nil) do
    @transaction.set_error(transaction, reason, message, stack)
    @transaction.set_meta_data(transaction, metadata)
    @transaction.finish(transaction)
    @transaction.complete(transaction)

    Logger.debug(fn ->
      "Submitting #{inspect(transaction)}: #{message}"
    end)

    transaction
  end

  if Appsignal.plug?() do
    def submit_transaction(transaction, reason, message, stack, metadata, conn) do
      if conn do
        @transaction.set_request_metadata(transaction, conn)
      end

      submit_transaction(transaction, reason, message, stack, metadata)
    end
  end

  @doc false
  @spec match_event(term) :: {pid, term, String.t(), list, %{}} | :nomatch
  def match_event({:error_report, _gleader, {origin, :crash_report, [report | _]}})
      when is_list(report) do
    {_kind, error, stack} = report[:error_info]
    {origin, error, stack, %{}}
  rescue
    exception ->
      Logger.warn(fn ->
        """
        AppSignal: Failed to match error report: #{Exception.message(exception)}
        #{inspect(report[:error_info])}
        """
      end)

      :nomatch
  end

  def match_event(_event) do
    :nomatch
  end

  @doc false
  @deprecated "Use Appsignal.ErrorLoggerHandler.init/1 instead."
  def init(state) do
    Appsignal.ErrorLoggerHandler.init(state)
  end

  @doc false
  @deprecated "Use Appsignal.ErrorLoggerHandler.handle_event/2 instead."
  def handle_event(event, state) do
    Appsignal.ErrorLoggerHandler.handle_event(event, state)
  end

  @doc false
  @deprecated "Use Appsignal.ErrorLoggerHandler.handle_info/2 instead."
  def handle_info(info, state) do
    Appsignal.ErrorLoggerHandler.handle_info(info, state)
  end

  @doc false
  @deprecated "Use Appsignal.Backtrace.from_stacktrace/1 instead."
  def format_stack(stacktrace) do
    Backtrace.from_stacktrace(stacktrace)
  end

  @deprecated "Use Appsignal.Error.metadata/1 instead."
  def extract_reason_and_message(any, prefix) do
    {exception, _} = Error.normalize(any, [])
    {name, message} = Error.metadata(exception)
    {name, prefixed(prefix, message)}
  end

  defp prefixed(nil, msg), do: msg
  defp prefixed("", msg), do: msg
  defp prefixed(pre, msg), do: pre <> ": " <> msg

  @pid_or_ref_regex ~r/\<(\d+\.)+\d+\>/
  @deprecated "Use Appsignal.Error.metadata/1 instead."
  def normalize_reason(reason) do
    Regex.replace(@pid_or_ref_regex, reason, "<...>")
  end
end
