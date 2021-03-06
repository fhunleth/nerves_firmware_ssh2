defmodule SSHSubsystemFwup do
  @moduledoc """
  SSH subsystem for upgrading Nerves devices

  This module provides an SSH subsystem for Erlang's `ssh` application. This
  makes it possible to send firmware updates to Nerves devices using plain old
  `ssh` like this:

  ```shell
  cat $firmware | ssh -s $ip_address fwup
  ```

  Where `$ip_address` is the IP address of your Nerves device. Depending on how
  you have Erlang's `ssh` application set up, you may need to pass more
  parameters (like username, port, identities, etc.).

  See [`nerves_ssh`](https://github.com/nerves-project/nerves_ssh/) for an easy
  way to set this up. If you don't want to use `nerves_ssh`, then in your call
  to `:ssh.daemon` add the return value from
  `SSHSubsystemFwup.subsystem_spec/1`:

  ```elixir
  devpath = Nerves.Runtime.KV.get("nerves_fw_devpath")

  :ssh.daemon([
        {:subsystems, [SSHSubsystemFwup.subsystem_spec(devpath: devpath)]}
      ])
  ```

  See `SSHSubsystemFwup.subsystem_spec/1` for options. You will almost always
  need to pass the path to the device that should be updated since that is
  device-specific.
  """

  @typedoc """
  Options:

  * `:devpath` - path for fwup to upgrade (Required)
  * `:fwup_path` - path to the fwup firmware update utility
  * `:fwup_extra_options` - additional options to pass to fwup like for setting
    public keys
  * `:success_callback` - an MFA to call when a firmware update completes
    successfully. Defaults to `{Nerves.Runtime, :reboot, []}`.
  * `:task` - the task to run in the firmware update. Defaults to `"upgrade"`
  """
  @behaviour :ssh_client_channel
  @type options :: [
          devpath: Path.t(),
          fwup_path: Path.t(),
          fwup_extra_options: [String.t()],
          task: String.t(),
          success_callback: mfa()
        ]

  require Logger

  alias SSHSubsystemFwup.FwupPort

  @doc """
  Helper for creating the SSH subsystem spec
  """
  @spec subsystem_spec(options()) :: :ssh.subsystem_spec()
  def subsystem_spec(options \\ []) do
    {'fwup', {__MODULE__, options}}
  end

  defmodule State do
    @moduledoc false
    defstruct state: :running_fwup,
              id: nil,
              cm: nil,
              fwup: nil,
              options: []
  end

  @impl true
  def init(options) do
    combined_options = Keyword.merge(default_options(), options)

    {:ok, %State{options: combined_options}}
  end

  defp default_options() do
    [
      devpath: "",
      fwup_path: System.find_executable("fwup"),
      fwup_extra_options: [],
      task: "upgrade",
      success_callback: {Nerves.Runtime, :reboot, []}
    ]
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, cm}, state) do
    devpath = state.options[:devpath]

    if is_binary(devpath) and File.exists?(devpath) do
      Logger.debug("ssh_subsystem_fwup: starting fwup")
      fwup = FwupPort.open_port(state.options)
      {:ok, %{state | id: channel_id, cm: cm, fwup: fwup}}
    else
      _ = :ssh_connection.send(cm, channel_id, "fwup devpath is invalid: #{inspect(devpath)}")
      :ssh_connection.exit_status(cm, channel_id, 1)
      :ssh_connection.close(cm, channel_id)
      {:stop, :normal, state}
    end
  end

  def handle_msg({port, message}, %{fwup: port} = state) do
    case FwupPort.handle_port(port, message) do
      {:respond, response} ->
        _ = :ssh_connection.send(state.cm, state.id, response)

        {:ok, state}

      {:done, response, status} ->
        _ = if response != "", do: :ssh_connection.send(state.cm, state.id, response)
        _ = :ssh_connection.send_eof(state.cm, state.id)
        _ = :ssh_connection.exit_status(state.cm, state.id, status)
        :ssh_connection.close(state.cm, state.id)
        Logger.debug("ssh_subsystem_fwup: fwup exited with status #{status}")
        run_callback(status, state.options[:success_callback])
        {:stop, :normal, state}
    end
  end

  def handle_msg({:EXIT, port, _reason}, %{fwup: port} = state) do
    _ = :ssh_connection.send_eof(state.cm, state.id)
    _ = :ssh_connection.exit_status(state.cm, state.id, 1)
    :ssh_connection.close(state.cm, state.id)
    {:stop, :normal, state}
  end

  def handle_msg(message, state) do
    Logger.debug("Ignoring message #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, 0, data}}, state) do
    FwupPort.send_data(state.fwup, data)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, 1, _data}}, state) do
    # Ignore stderr
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel_id}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _, _}}, state) do
    # Ignore signals
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_signal, _channel_id, _, _error, _}}, state) do
    {:stop, :normal, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_status, _channel_id, _status}}, state) do
    {:stop, :normal, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, message}, state) do
    Logger.debug("Ignoring handle_ssh_msg #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, :error, state}
  end

  @impl true
  def handle_cast(_message, state) do
    {:noreply, state}
  end

  defp run_callback(0 = _rc, {m, f, a}) do
    # Let others know that fwup was successful. The usual operation
    # here is to reboot. Run the callback in its own process so that
    # any issues with it don't affect processing here.
    _ = spawn(m, f, a)
    :ok
  end

  defp run_callback(_rc, _mfa), do: :ok

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  def code_change(_old, state, _extra) do
    {:ok, state}
  end
end
