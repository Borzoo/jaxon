defmodule Jaxon.Reader do
  alias Jaxon.{Decoder, Path}

  @behaviour Decoder

  @spec stream_to_rows!(Stream.t(), [Path.json_path()]) :: {:ok, Stream.t()}
  def stream_to_rows!(bin_stream, queries) do
    decoder = Jaxon.make_decoder()

    queries =
      queries
      |> Enum.map(&Path.parse!(&1))

    root =
      queries
      |> List.zip()
      |> Enum.reduce_while([], fn segment, acc ->
        segment
        |> Tuple.to_list()
        |> Enum.min_max()
        |> case do
          {a, a} ->
            {:cont, acc ++ [a]}

          _ ->
            {:halt, acc}
        end
      end)

    initial_state = {decoder, [], {root, queries, [], nil}, ""}

    bin_stream
    |> Stream.transform(
      fn -> initial_state end,
      fn chunk, {decoder, path, state, rest} ->
        binary = rest <> chunk

        case Decoder.decode(binary, decoder, __MODULE__, {path, state}) do
          {:error, path} ->
            {:halt, {:error, path}}

          {decoder, path, {root, queries, [], record}, rest} ->
            {[], {decoder, path, {root, queries, [], record}, rest}}

          {decoder, path, {root, queries, results, record}, rest} ->
            final_results =
              results
              |> Enum.flat_map(fn set ->
                m = Enum.reduce(set, 0, fn e, m -> max(m, length(e)) end)

                set
                |> Enum.map(&(&1 ++ :lists.duplicate(m - length(&1), nil)))
                |> transpose
              end)

            {final_results, {decoder, path, {root, queries, [], record}, rest}}
        end
      end,
      fn
        {:error, err} -> raise Jaxon.ParseError, message: err
        acc -> acc
      end
    )
  end

  defp match_query([:all | query], [_ | path]) do
    match_query(query, path)
  end

  defp match_query([fragment | query], [fragment | path]) do
    match_query(query, path)
  end

  defp match_query([], rest) do
    {:ok, rest}
  end

  defp match_query(_, _) do
    nil
  end

  defp query_exact_match?([:all | query], [_ | path]) do
    query_exact_match?(query, path)
  end

  defp query_exact_match?([fragment | query], [fragment | path]) do
    query_exact_match?(query, path)
  end

  defp query_exact_match?([], []) do
    true
  end

  defp query_exact_match?(_, _) do
    false
  end

  def close({root, queries, results, record}, path) do
    path = [:root | Enum.reverse(path)]

    if query_exact_match?(root, path) do
      results =
        results ++
          [
            Enum.map(queries, fn q ->
              {:ok, query} = match_query(root, q)
              access(record, query, [])
            end)
          ]

      {root, queries, results, nil}
    else
      {root, queries, results, record}
    end
  end

  def insert(state = {root, queries, results, record}, path, value) do
    reversed_path = [:root | Enum.reverse(path)]

    case match_query(root, reversed_path) do
      {:ok, rest} ->
        cond do
          !is_list(value) && !is_map(value) ->
            {root, queries, results, do_insert(record, rest, value)}
            |> close(path)

          true ->
            {root, queries, results, do_insert(record, rest, value)}
        end

      nil ->
        state
    end
  end

  defp do_insert(_record, [], value) do
    value
  end

  defp do_insert(record, [key], value) when is_integer(key) and is_list(record) do
    record ++ [value]
  end

  defp do_insert(record, [key | path], value) when is_list(record) do
    List.update_at(record, key, &do_insert(&1, path, value))
  end

  defp do_insert(record, [key | path], value) when is_map(record) do
    Map.update(record, key, value, fn inner ->
      do_insert(inner, path, value)
    end)
  end

  defp access(record, [], acc) do
    acc ++ [record]
  end

  defp access(record, [:root | path], acc) do
    access(record, path, acc)
  end

  defp access(record, [:all | path], acc) do
    Enum.reduce(record, acc, fn inner, acc ->
      access(inner, path, acc)
    end)
  end

  defp access(record, [key | path], acc)
       when is_list(record) and length(record) > 0 and key >= 0 do
    access(:lists.nth(key + 1, record), path, acc)
  end

  defp access(record, [key | path], acc) when is_map(record) and is_binary(key) do
    case record do
      %{^key => inner} ->
        access(inner, path, acc)

      _ ->
        acc
    end
  end

  defp access(_, _, acc) do
    acc
  end

  defp transpose([[x | xs] | xss]) do
    [[x | for([h | _] <- xss, do: h)] | transpose([xs | for([_ | t] <- xss, do: t)])]
  end

  defp transpose([[] | xss]), do: transpose(xss)
  defp transpose([]), do: []
end