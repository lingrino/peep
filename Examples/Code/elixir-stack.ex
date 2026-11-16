defmodule Stack do
  @moduledoc "A stack as a GenServer."
  use GenServer

  def start_link(initial \\ []), do: GenServer.start_link(__MODULE__, initial)
  def push(pid, item), do: GenServer.cast(pid, {:push, item})
  def pop(pid), do: GenServer.call(pid, :pop)

  @impl true
  def init(items), do: {:ok, items}

  @impl true
  def handle_cast({:push, item}, items), do: {:noreply, [item | items]}

  @impl true
  def handle_call(:pop, _from, [top | rest]), do: {:reply, top, rest}
  def handle_call(:pop, _from, []), do: {:reply, nil, []}
end
