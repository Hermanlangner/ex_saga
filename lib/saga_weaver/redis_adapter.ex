defmodule SagaWeaver.RedisAdapter do
  @behaviour SagaWeaver.AdapterBehaviour

  alias SagaWeaver.SagaEntity
  alias Redix

  @redis_url "redis://localhost:6379"

  # Optimistic locking function
  defp execute_with_optimistic_lock(key, fun) do
    with {:ok, conn} <- connection(),
         {:ok, _} <- Redix.command(conn, ["WATCH", key]) do
      result = fun.()

      case Redix.pipeline(conn, [["MULTI"] | result ++ [["EXEC"]]]) do
        {:ok, ["OK" | _]} -> :ok
        {:ok, nil} -> {:error, :transaction_failed}
        error -> handle_error(error)
      end
    else
      error -> handle_error(error)
    end
  end

  def create_saga_instance(%SagaEntity{} = saga) do
    execute_with_optimistic_lock(saga.unique_identifier, fn ->
      [["SET", saga.unique_identifier, encode_entity(saga)]]
    end)
    |> case do
      :ok -> {:ok, saga}
      error -> error
    end
  end

  def find_saga_instance(key) do
    case fetch_record(key) do
      {:ok, nil} -> nil
      {:ok, saga} -> {:ok, decode_entity(saga)}
      {:error, _} = error -> error
    end
  end

  def mark_as_completed(%SagaEntity{} = saga) do
    updated_saga = %SagaEntity{saga | marked_as_completed: true}

    execute_with_optimistic_lock(saga.unique_identifier, fn ->
      [["SET", saga.unique_identifier, encode_entity(updated_saga)]]
    end)
    |> case do
      :ok -> {:ok, updated_saga}
      error -> error
    end
  end

  def delete_saga_instance(%SagaEntity{} = saga) do
    execute_with_optimistic_lock(saga.unique_identifier, fn ->
      [["DEL", saga.unique_identifier]]
    end)
  end

  def assign_state(%SagaEntity{} = saga, state) do
    updated_saga = %SagaEntity{saga | states: state}

    execute_with_optimistic_lock(saga.unique_identifier, fn ->
      [["SET", saga.unique_identifier, encode_entity(updated_saga)]]
    end)
    |> case do
      :ok -> {:ok, updated_saga}
      error -> error
    end
  end

  def assign_context(%SagaEntity{} = saga, context) do
    updated_saga = %SagaEntity{saga | context: context}

    execute_with_optimistic_lock(saga.unique_identifier, fn ->
      [["SET", saga.unique_identifier, encode_entity(updated_saga)]]
    end)
    |> case do
      :ok -> {:ok, updated_saga}
      error -> error
    end
  end

  # Redis operations

  defp write_record(key, value) do
    connection()
    |> Redix.command(["SET", key, encode_entity(value)])
    |> handle_response()
  end

  defp fetch_record(key) do
    connection()
    |> Redix.command(["GET", key])
    |> handle_response()
  end

  defp delete_record(key) do
    connection()
    |> Redix.command(["DEL", key])
    |> handle_response()
  end

  # Helper functions

  defp connection() do
    case Redix.start_link(@redis_url) do
      {:ok, conn} -> {:ok, conn}
      error -> handle_error(error)
    end
  end

  defp handle_response({:ok, result}), do: {:ok, result}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp handle_error({:error, reason}) do
    Logger.error("Redis error: #{inspect(reason)}")
    {:error, reason}
  end

  defp encode_entity(entity) do
    :erlang.term_to_binary(entity)
  end

  defp decode_entity(binary) do
    :erlang.binary_to_term(binary)
  end
end