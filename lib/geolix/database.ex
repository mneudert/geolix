defmodule Geolix.Database do
  use Bitwise, only_operators: true

  require Logger

  alias Geolix.Metadata
  alias Geolix.Storage.Metadata

  @doc """
  Looks up information for the given ip in all databases.
  """
  @spec lookup(tuple, map) :: map
  def lookup(ip, databases) do
    lookup_all(ip, databases, Map.keys(databases), %{})
  end

  defp lookup_all(_, _, [], results), do: results
  defp lookup_all(ip, databases, [ where | rest ], results) do
    result  = lookup(where, ip, databases)
    results = Map.put(results, where, result)

    lookup_all(ip, databases, rest, results)
  end

  @doc """
  Looks up information for the given ip in the given database.
  """
  @spec lookup(atom, tuple, map) :: nil | map
  def lookup(where, ip, databases) do
    meta     = Metadata.get(where)
    database = Map.get(databases, where)

    case { meta, database } do
      { nil, _   }       -> nil
      { _,   nil }       -> nil
      { meta, database } ->
        parse_lookup_tree(ip, database.tree, meta)
          |> lookup_pointer(database, meta.node_count)
    end
  end

  defp lookup_pointer(0, _, _), do: nil
  defp lookup_pointer(ptr, database, node_count) do
    offset        = ptr - node_count - 16
    { result, _ } = Geolix.Decoder.decode(database.data, offset)

    result
  end

  @doc """
  Proxy method for Geolix.Reader.read_database/1
  """
  @spec read_database(String.t) :: { binary, binary, Geolix.Metadata.t }
  def read_database(filename) do
         filename
      |> Geolix.Reader.read_database()
      |> split_data()
  end

  defp parse_lookup_tree(ip, tree, meta) do
    start_node = get_start_node(32, meta)

    parse_lookup_tree_bitwise(ip, 0, 32, start_node, tree, meta)
  end

  defp split_data({ data, meta }) do
    { meta, _ } = meta |> Geolix.Decoder.decode()

    meta           = struct(%Geolix.Metadata{}, meta)
    record_size    = Map.get(meta, :record_size)
    node_count     = Map.get(meta, :node_count)
    node_byte_size = div(record_size, 4)
    tree_size      = node_count * node_byte_size

    meta = %Geolix.Metadata{ meta | node_byte_size: node_byte_size }
    meta = %Geolix.Metadata{ meta | tree_size:      tree_size }

    tree      = data |> binary_part(0, tree_size)
    data_size = byte_size(data) - byte_size(tree) - 16
    data      = data |> binary_part(tree_size + 16, data_size)

    { tree, data, meta }
  end

  defp parse_lookup_tree_bitwise(ip, bit, bit_count, node, tree, meta)
      when bit < bit_count
  do
    if node >= meta.node_count do
      parse_lookup_tree_bitwise(nil, nil, nil, node, nil, meta)
    else
      temp_bit = 0xFF &&& elem(ip, bit >>> 3)
      node_bit = 1 &&& (temp_bit >>> 7 - rem(bit, 8))
      node     = read_node(node, node_bit, tree, meta)

      parse_lookup_tree_bitwise(ip, bit + 1, bit_count, node, tree, meta)
    end
  end
  defp parse_lookup_tree_bitwise(_, _, _, node, _, meta) do
    node_count = meta.node_count

    cond do
      node >  node_count -> node
      node == node_count -> 0
      true ->
        Logger.error "Invalid node below node_count: #{node}"
        0
    end
  end

  defp get_start_node(32, meta) do
    case meta.ip_version do
      6 -> 96
      _ -> 0
    end
  end

  defp read_node(node, index, tree, meta) do
    read_node_by_size(meta.record_size, tree, node * meta.node_byte_size, index)
  end

  defp read_node_by_size(24, tree, offset, index) do
    tree |> binary_part(offset + index * 3, 3) |> decode_uint
  end
  defp read_node_by_size(28, tree, offset, index) do
    middle =
         tree
      |> binary_part(offset + 3, 1)
      |> :erlang.bitstring_to_list()
      |> hd()

    middle = 0xF0 &&& middle

    if 0 == index do
      middle = middle >>> 4
    end

    middle = middle |> List.wrap() |> :erlang.list_to_bitstring()
    bytes  = tree |> binary_part(offset + index * 4, 3)

    decode_uint(middle <> bytes)
  end
  defp read_node_by_size(size, _, _, _) do
    Logger.error "Unhandled record_size '#{ size }'!"
    0
  end

  defp decode_uint(bin) do
    bin
      |> :binary.bin_to_list()
      |> Enum.map( &Integer.to_string(&1, 16) )
      |> Enum.join()
      |> String.to_char_list()
      |> List.to_integer(16)
  end
end
