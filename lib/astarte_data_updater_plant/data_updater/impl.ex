#
# This file is part of Astarte.
#
# Copyright 2017 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.DataUpdaterPlant.DataUpdater.Impl do
  alias Astarte.Core.CQLUtils
  alias Astarte.Core.Device
  alias Astarte.Core.InterfaceDescriptor
  alias Astarte.Core.Mapping
  alias Astarte.Core.Mapping.EndpointsAutomaton
  alias Astarte.Core.Mapping.ValueType
  alias Astarte.DataUpdaterPlant.DataUpdater.State
  alias Astarte.Core.Triggers.DataTrigger
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.DataTrigger, as: ProtobufDataTrigger
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.Utils, as: SimpleTriggersProtobufUtils
  alias Astarte.DataAccess.Data
  alias Astarte.DataAccess.Database
  alias Astarte.DataAccess.Device, as: DeviceQueries
  alias Astarte.DataAccess.Interface, as: InterfaceQueries
  alias Astarte.DataAccess.Mappings
  alias Astarte.DataUpdaterPlant.DataUpdater.Cache
  alias Astarte.DataUpdaterPlant.DataUpdater.CachedPath
  alias Astarte.DataUpdaterPlant.DataUpdater.EventTypeUtils
  alias Astarte.DataUpdaterPlant.DataUpdater.PayloadsDecoder
  alias Astarte.DataUpdaterPlant.DataUpdater.Queries
  alias Astarte.DataUpdaterPlant.MessageTracker
  alias Astarte.DataUpdaterPlant.RPC.VMQPlugin
  alias Astarte.DataUpdaterPlant.TriggersHandler
  alias Astarte.DataUpdaterPlant.ValueMatchOperators
  require Logger

  @paths_cache_size 32
  @interface_lifespan_decimicroseconds 60 * 10 * 1000 * 10000
  @device_triggers_lifespan_decimicroseconds 60 * 10 * 1000 * 10000

  def init_state(realm, device_id, message_tracker) do
    MessageTracker.register_data_updater(message_tracker)
    Process.monitor(message_tracker)

    new_state = %State{
      realm: realm,
      device_id: device_id,
      message_tracker: message_tracker,
      connected: true,
      interfaces: %{},
      interface_ids_to_name: %{},
      interfaces_by_expiry: [],
      mappings: %{},
      paths_cache: Cache.new(@paths_cache_size),
      device_triggers: %{},
      data_triggers: %{},
      volatile_triggers: [],
      introspection_triggers: %{},
      last_seen_message: 0,
      last_device_triggers_refresh: 0
    }

    {:ok, db_client} = Database.connect(new_state.realm)

    stats_and_introspection =
      Queries.retrieve_device_stats_and_introspection!(db_client, device_id)

    {:ok, ttl} = Queries.fetch_datastream_maximum_storage_retention(db_client)

    Map.merge(new_state, stats_and_introspection)
    |> Map.put(:datastream_maximum_storage_retention, ttl)
  end

  def handle_connection(state, ip_address_string, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    timestamp_ms = div(timestamp, 10_000)

    ip_address_result =
      ip_address_string
      |> to_charlist()
      |> :inet.parse_address()

    ip_address =
      case ip_address_result do
        {:ok, ip_address} ->
          ip_address

        _ ->
          warn(new_state, "received invalid IP address #{ip_address_string}.")
          {0, 0, 0, 0}
      end

    Queries.set_device_connected!(
      db_client,
      new_state.device_id,
      timestamp_ms,
      ip_address
    )

    trigger_targets = Map.get(new_state.device_triggers, :on_device_connection, [])
    device_id_string = Device.encode_device_id(new_state.device_id)

    TriggersHandler.device_connected(
      trigger_targets,
      new_state.realm,
      device_id_string,
      ip_address_string,
      timestamp_ms
    )

    MessageTracker.ack_delivery(new_state.message_tracker, message_id)
    %{new_state | connected: true, last_seen_message: timestamp}
  end

  def handle_disconnection(state, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    timestamp_ms = div(timestamp, 10_000)

    Queries.set_device_disconnected!(
      db_client,
      new_state.device_id,
      timestamp_ms,
      new_state.total_received_msgs,
      new_state.total_received_bytes
    )

    trigger_targets = Map.get(new_state.device_triggers, :on_device_disconnection, [])
    device_id_string = Device.encode_device_id(new_state.device_id)

    TriggersHandler.device_disconnected(
      trigger_targets,
      new_state.realm,
      device_id_string,
      timestamp_ms
    )

    MessageTracker.ack_delivery(new_state.message_tracker, message_id)
    %{new_state | connected: false, last_seen_message: timestamp}
  end

  defp execute_incoming_data_triggers(
         state,
         device,
         interface,
         interface_id,
         path,
         endpoint_id,
         payload,
         value,
         timestamp
       ) do
    realm = state.realm

    # any interface triggers
    get_on_data_triggers(state, :on_incoming_data, :any_interface, :any_endpoint)
    |> Enum.each(fn trigger ->
      targets = trigger.trigger_targets
      TriggersHandler.incoming_data(targets, realm, device, interface, path, payload, timestamp)
    end)

    # any endpoint triggers
    get_on_data_triggers(state, :on_incoming_data, interface_id, :any_endpoint)
    |> Enum.each(fn trigger ->
      targets = trigger.trigger_targets
      TriggersHandler.incoming_data(targets, realm, device, interface, path, payload, timestamp)
    end)

    # incoming data triggers
    get_on_data_triggers(state, :on_incoming_data, interface_id, endpoint_id, path, value)
    |> Enum.each(fn trigger ->
      targets = trigger.trigger_targets
      TriggersHandler.incoming_data(targets, realm, device, interface, path, payload, timestamp)
    end)

    :ok
  end

  defp get_value_change_triggers(state, interface_id, endpoint_id, path, value) do
    value_change_triggers =
      get_on_data_triggers(state, :on_value_change, interface_id, endpoint_id, path, value)

    value_change_applied_triggers =
      get_on_data_triggers(
        state,
        :on_value_change_applied,
        interface_id,
        endpoint_id,
        path,
        value
      )

    path_created_triggers =
      get_on_data_triggers(state, :on_path_created, interface_id, endpoint_id, path, value)

    path_removed_triggers =
      get_on_data_triggers(state, :on_path_removed, interface_id, endpoint_id, path)

    if value_change_triggers != [] or value_change_applied_triggers != [] or
         path_created_triggers != [] do
      {:ok,
       {value_change_triggers, value_change_applied_triggers, path_created_triggers,
        path_removed_triggers}}
    else
      {:no_value_change_triggers, nil}
    end
  end

  defp execute_pre_change_triggers(
         {value_change_triggers, _, _, _},
         realm,
         device_id_string,
         interface_name,
         path,
         previous_value,
         value,
         timestamp
       ) do
    old_bson_value = Bson.encode(%{v: previous_value})
    payload = Bson.encode(%{v: value})

    if previous_value != value do
      Enum.each(value_change_triggers, fn trigger ->
        TriggersHandler.value_change(
          trigger.trigger_targets,
          realm,
          device_id_string,
          interface_name,
          path,
          old_bson_value,
          payload,
          timestamp
        )
      end)
    end

    :ok
  end

  defp execute_post_change_triggers(
         {_, value_change_applied_triggers, path_created_triggers, path_removed_triggers},
         realm,
         device,
         interface,
         path,
         previous_value,
         value,
         timestamp
       ) do
    old_bson_value = Bson.encode(%{v: previous_value})
    payload = Bson.encode(%{v: value})

    if previous_value == nil and value != nil do
      Enum.each(path_created_triggers, fn trigger ->
        targets = trigger.trigger_targets
        TriggersHandler.path_created(targets, realm, device, interface, path, payload, timestamp)
      end)
    end

    if previous_value != nil and value == nil do
      Enum.each(path_removed_triggers, fn trigger ->
        targets = trigger.trigger_targets
        TriggersHandler.path_removed(targets, realm, device, interface, path, timestamp)
      end)
    end

    if previous_value != value do
      Enum.each(value_change_applied_triggers, fn trigger ->
        targets = trigger.trigger_targets

        TriggersHandler.value_change_applied(
          targets,
          realm,
          device,
          interface,
          path,
          old_bson_value,
          payload,
          timestamp
        )
      end)
    end

    :ok
  end

  def handle_data(state, interface, path, payload, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    with :ok <- validate_path(path),
         maybe_descriptor <- Map.get(new_state.interfaces, interface),
         {:ok, interface_descriptor, new_state} <-
           maybe_handle_cache_miss(maybe_descriptor, interface, new_state, db_client),
         :ok <- can_write_on_interface?(interface_descriptor),
         interface_id <- interface_descriptor.interface_id,
         {:ok, endpoint} <- resolve_path(path, interface_descriptor, new_state.mappings),
         endpoint_id <- endpoint.endpoint_id,
         {value, value_timestamp, _metadata} <-
           PayloadsDecoder.decode_bson_payload(payload, timestamp),
         expected_types <-
           extract_expected_types(path, interface_descriptor, endpoint, new_state.mappings),
         :ok <- validate_value_type(expected_types, value) do
      device_id_string = Device.encode_device_id(new_state.device_id)

      maybe_explicit_value_timestamp =
        if endpoint.explicit_timestamp do
          value_timestamp
        else
          div(timestamp, 10000)
        end

      execute_incoming_data_triggers(
        new_state,
        device_id_string,
        interface_descriptor.name,
        interface_id,
        path,
        endpoint_id,
        payload,
        value,
        maybe_explicit_value_timestamp
      )

      {has_change_triggers, change_triggers} =
        get_value_change_triggers(new_state, interface_id, endpoint_id, path, value)

      previous_value =
        with {:has_change_triggers, :ok} <- {:has_change_triggers, has_change_triggers},
             {:ok, property_value} <-
               Data.fetch_property(
                 db_client,
                 new_state.device_id,
                 interface_descriptor,
                 endpoint,
                 path
               ) do
          property_value
        else
          {:has_change_triggers, _not_ok} ->
            nil

          {:error, :property_not_set} ->
            nil
        end

      if has_change_triggers == :ok do
        :ok =
          execute_pre_change_triggers(
            change_triggers,
            new_state.realm,
            device_id_string,
            interface_descriptor.name,
            path,
            previous_value,
            value,
            maybe_explicit_value_timestamp
          )
      end

      cond do
        interface_descriptor.type == :datastream and value != nil ->
          :ok =
            cond do
              Cache.has_key?(new_state.paths_cache, {interface, path}) ->
                :ok

              is_still_valid?(
                Queries.fetch_path_expiry(
                  db_client,
                  new_state.device_id,
                  interface_descriptor,
                  endpoint,
                  path
                ),
                state.datastream_maximum_storage_retention
              ) ->
                :ok

              true ->
                Queries.insert_path_into_db(
                  db_client,
                  new_state.device_id,
                  interface_descriptor,
                  endpoint,
                  path,
                  maybe_explicit_value_timestamp,
                  timestamp,
                  ttl: path_ttl(state.datastream_maximum_storage_retention)
                )
            end

        interface_descriptor.type == :datastream ->
          warn(new_state, "tried to unset a datastream")
          MessageTracker.discard(new_state.message_tracker, message_id)
          raise "Unsupported"

        true ->
          :ok
      end

      # TODO: handle insert failures here
      insert_result =
        Queries.insert_value_into_db(
          db_client,
          new_state.device_id,
          interface_descriptor,
          endpoint,
          path,
          value,
          maybe_explicit_value_timestamp,
          timestamp,
          ttl: state.datastream_maximum_storage_retention
        )

      :ok = insert_result

      if has_change_triggers == :ok do
        :ok =
          execute_post_change_triggers(
            change_triggers,
            new_state.realm,
            device_id_string,
            interface_descriptor.name,
            path,
            previous_value,
            value,
            maybe_explicit_value_timestamp
          )
      end

      ttl = state.datastream_maximum_storage_retention
      paths_cache = Cache.put(new_state.paths_cache, {interface, path}, %CachedPath{}, ttl)
      new_state = %{new_state | paths_cache: paths_cache}

      MessageTracker.ack_delivery(new_state.message_tracker, message_id)
      update_stats(new_state, interface, path, payload)
    else
      {:error, :cannot_write_on_server_owned_interface} ->
        warn(
          new_state,
          "tried to write on server owned interface: #{interface} on " <>
            "path: #{path}, payload: #{inspect(payload)}, timestamp: #{inspect(timestamp)}."
        )

        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :invalid_path} ->
        warn(new_state, "received invalid path: #{path}.")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :mapping_not_found} ->
        warn(
          new_state,
          "mapping not found for #{interface}#{path}. Maybe outdated introspection?"
        )

        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :interface_loading_failed} ->
        warn(new_state, "cannot load interface: #{interface}.")
        # TODO: think about additional actions since the problem
        # could be a missing interface in the DB
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:guessed, _guessed_endpoints} ->
        warn(new_state, "mapping guessed for #{interface}#{path}. Maybe outdated introspection?")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :undecodable_bson_payload} ->
        warn(state, "invalid BSON payload: #{inspect(payload)} sent to #{interface}#{path}.")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :unexpected_value_type} ->
        warn(state, "received invalid value: #{inspect(payload)} sent to #{interface}#{path}.")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :value_size_exceeded} ->
        warn(state, "received huge payload: #{inspect(payload)} sent to #{interface}#{path}.")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)

      {:error, :unexpected_object_key} ->
        warn(state, "object has unexpected key: #{inspect(payload)} sent to #{interface}#{path}.")
        ask_clean_session(new_state)
        MessageTracker.discard(new_state.message_tracker, message_id)
        update_stats(new_state, interface, path, payload)
    end
  end

  defp path_ttl(nil) do
    nil
  end

  defp path_ttl(retention_secs) do
    retention_secs * 2 + div(retention_secs, 2)
  end

  defp is_still_valid?({:error, :property_not_set}, _ttl) do
    false
  end

  defp is_still_valid?({:ok, :no_expiry}, _ttl) do
    true
  end

  defp is_still_valid?({:ok, _expiry_date}, nil) do
    false
  end

  defp is_still_valid?({:ok, expiry_date}, ttl) do
    expiry_secs = DateTime.to_unix(expiry_date)

    now_secs =
      DateTime.utc_now()
      |> DateTime.to_unix()

    # 3600 seconds is one hour
    # this adds 1 hour of tolerance to clock synchronization issues
    now_secs + ttl + 3600 < expiry_secs
  end

  defp validate_path(path) do
    # TODO: this is a temporary fix to work around a bug in EndpointsAutomaton.resolve_path/2
    if String.contains?(path, "//") do
      {:error, :invalid_path}
    else
      :ok
    end
  end

  def validate_value_type(expected_type, %Bson.UTC{} = value) do
    ValueType.validate_value(expected_type, value)
  end

  def validate_value_type(expected_type, %Bson.Bin{} = value) do
    ValueType.validate_value(expected_type, value)
  end

  # Explicitly match on all structs to avoid pattern matching them as maps below
  def validate_value_type(_expected_type, %_{} = _unsupported_struct) do
    {:error, :unexpected_value_type}
  end

  def validate_value_type(expected_types, %{} = object) do
    Enum.reduce_while(object, :ok, fn {path, value}, _acc ->
      key = Atom.to_string(path)

      with {:ok, expected_type} <- Map.fetch(expected_types, key),
           :ok <- ValueType.validate_value(expected_type, value) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, reason}}

        :error ->
          {:halt, {:error, :unexpected_object_key}}
      end
    end)
  end

  def validate_value_type(expected_type, value) do
    if value != nil do
      ValueType.validate_value(expected_type, value)
    else
      :ok
    end
  end

  defp extract_expected_types(_path, interface_descriptor, endpoint, mappings) do
    case interface_descriptor.aggregation do
      :individual ->
        endpoint.value_type

      :object ->
        # TODO: we should probably cache this
        Enum.flat_map(mappings, fn {_id, mapping} ->
          if mapping.interface_id == interface_descriptor.interface_id do
            expected_key =
              mapping.endpoint
              |> String.split("/")
              |> List.last()

            [{expected_key, mapping.value_type}]
          else
            []
          end
        end)
        |> Enum.into(%{})
    end
  end

  defp update_stats(state, interface, path, payload) do
    %{
      state
      | total_received_msgs: state.total_received_msgs + 1,
        total_received_bytes:
          state.total_received_bytes + byte_size(payload) + byte_size(interface) + byte_size(path)
    }
  end

  def handle_introspection(state, payload, message_id, timestamp) do
    with {:ok, new_introspection_list} <- PayloadsDecoder.parse_introspection(payload) do
      process_introspection(state, new_introspection_list, payload, message_id, timestamp)
    else
      {:error, :invalid_introspection} ->
        warn(state, "discarding invalid introspection: #{inspect(payload)}.")
        ask_clean_session(state)
        MessageTracker.discard(state.message_tracker, message_id)
        update_stats(state, "", "", payload)
    end
  end

  def process_introspection(state, new_introspection_list, payload, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    timestamp_ms = div(timestamp, 10_000)

    {db_introspection_map, db_introspection_minor_map} =
      List.foldl(new_introspection_list, {%{}, %{}}, fn {interface, major, minor},
                                                        {introspection_map,
                                                         introspection_minor_map} ->
        introspection_map = Map.put(introspection_map, interface, major)
        introspection_minor_map = Map.put(introspection_minor_map, interface, minor)

        {introspection_map, introspection_minor_map}
      end)

    any_interface_id = SimpleTriggersProtobufUtils.any_interface_object_id()

    %{introspection_triggers: introspection_triggers} =
      populate_triggers_for_object!(new_state, db_client, any_interface_id, :any_interface)

    realm = new_state.realm
    device_id_string = Device.encode_device_id(new_state.device_id)

    on_introspection_targets =
      Map.get(introspection_triggers, {:on_incoming_introspection, :any_interface}, [])

    TriggersHandler.incoming_introspection(
      on_introspection_targets,
      realm,
      device_id_string,
      payload,
      timestamp_ms
    )

    # TODO: implement here object_id handling for a certain interface name. idea: introduce interface_family_id

    current_sorted_introspection =
      new_state.introspection
      |> Enum.map(fn x -> x end)
      |> Enum.sort()

    new_sorted_introspection =
      db_introspection_map
      |> Enum.map(fn x -> x end)
      |> Enum.sort()

    diff = List.myers_difference(current_sorted_introspection, new_sorted_introspection)

    Enum.each(diff, fn {change_type, changed_interfaces} ->
      case change_type do
        :ins ->
          Logger.debug(
            "#{new_state.realm}: Interfaces #{inspect(changed_interfaces)} have been added to #{
              Device.encode_device_id(new_state.device_id)
            } ."
          )

          Enum.each(changed_interfaces, fn {interface_name, interface_major} ->
            :ok =
              if interface_major == 0 do
                Queries.register_device_with_interface(
                  db_client,
                  state.device_id,
                  interface_name,
                  0
                )
              else
                :ok
              end

            minor = Map.get(db_introspection_minor_map, interface_name)

            interface_added_targets =
              Map.get(introspection_triggers, {:on_interface_added, :any_interface}, [])

            TriggersHandler.interface_added(
              interface_added_targets,
              realm,
              device_id_string,
              interface_name,
              interface_major,
              minor,
              timestamp_ms
            )
          end)

        :del ->
          Logger.debug(
            "#{new_state.realm}: Interfaces #{inspect(changed_interfaces)} have been removed from #{
              Device.encode_device_id(new_state.device_id)
            } ."
          )

          Enum.each(changed_interfaces, fn {interface_name, interface_major} ->
            :ok =
              if interface_major == 0 do
                Queries.unregister_device_with_interface(
                  db_client,
                  state.device_id,
                  interface_name,
                  0
                )
              else
                :ok
              end

            interface_removed_targets =
              Map.get(introspection_triggers, {:on_interface_deleted, :any_interface}, [])

            TriggersHandler.interface_removed(
              interface_removed_targets,
              realm,
              device_id_string,
              interface_name,
              interface_major,
              timestamp_ms
            )
          end)

        :eq ->
          Logger.debug(
            "#{new_state.realm}: Interfaces #{inspect(changed_interfaces)} have not changed on #{
              Device.encode_device_id(new_state.device_id)
            } ."
          )
      end
    end)

    {added_interfaces, removed_interfaces} =
      Enum.reduce(diff, {%{}, %{}}, fn {change_type, changed_interfaces}, {add_acc, rm_acc} ->
        case change_type do
          :ins ->
            changed_map = Enum.into(changed_interfaces, %{})
            {Map.merge(add_acc, changed_map), rm_acc}

          :del ->
            changed_map = Enum.into(changed_interfaces, %{})
            {add_acc, Map.merge(rm_acc, changed_map)}

          :eq ->
            {add_acc, rm_acc}
        end
      end)

    {:ok, old_minors} = Queries.fetch_device_introspection_minors(db_client, state.device_id)

    readded_introspection = Enum.to_list(added_interfaces)

    old_introspection =
      Enum.reduce(removed_interfaces, %{}, fn {iface, _major}, acc ->
        prev_major = Map.fetch!(state.introspection, iface)
        prev_minor = Map.get(old_minors, iface, 0)
        Map.put(acc, {iface, prev_major}, prev_minor)
      end)

    :ok = Queries.add_old_interfaces(db_client, new_state.device_id, old_introspection)
    :ok = Queries.remove_old_interfaces(db_client, new_state.device_id, readded_introspection)

    # TODO: handle triggers for interface minor updates

    # Removed/updated interfaces must be purged away, otherwise data will be written using old
    # interface_id.
    remove_interfaces_list = Map.keys(removed_interfaces)

    {interfaces_to_drop_map, _} = Map.split(new_state.interfaces, remove_interfaces_list)
    interfaces_to_drop_list = Map.keys(interfaces_to_drop_map)

    # Forget interfaces wants a list of already loaded interfaces, otherwise it will crash
    new_state = forget_interfaces(new_state, interfaces_to_drop_list)

    Queries.update_device_introspection!(
      db_client,
      new_state.device_id,
      db_introspection_map,
      db_introspection_minor_map
    )

    MessageTracker.ack_delivery(new_state.message_tracker, message_id)

    %{
      new_state
      | introspection: db_introspection_map,
        paths_cache: Cache.new(@paths_cache_size),
        total_received_msgs: new_state.total_received_msgs + 1,
        total_received_bytes: new_state.total_received_bytes + byte_size(payload)
    }
  end

  def handle_control(state, "/producer/properties", <<0, 0, 0, 0>>, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    timestamp_ms = div(timestamp, 10_000)

    operation_result = prune_device_properties(new_state, "", timestamp_ms)

    if operation_result != :ok do
      Logger.debug("result is #{inspect(operation_result)} further actions should be required.")
    end

    MessageTracker.ack_delivery(new_state.message_tracker, message_id)

    %{
      new_state
      | total_received_msgs: new_state.total_received_msgs + 1,
        total_received_bytes:
          new_state.total_received_bytes + byte_size(<<0, 0, 0, 0>>) +
            byte_size("/producer/properties")
    }
  end

  def handle_control(state, "/producer/properties", payload, message_id, timestamp) do
    {:ok, db_client} = Database.connect(state.realm)

    new_state = execute_time_based_actions(state, timestamp, db_client)

    timestamp_ms = div(timestamp, 10_000)

    # TODO: check payload size, to avoid anoying crashes

    <<_size_header::size(32), zlib_payload::binary>> = payload

    decoded_payload = PayloadsDecoder.safe_inflate(zlib_payload)

    if decoded_payload != :error do
      operation_result = prune_device_properties(new_state, decoded_payload, timestamp_ms)

      if operation_result != :ok do
        Logger.debug("result is #{inspect(operation_result)} further actions should be required.")
      end
    end

    MessageTracker.ack_delivery(new_state.message_tracker, message_id)

    %{
      new_state
      | total_received_msgs: new_state.total_received_msgs + 1,
        total_received_bytes:
          new_state.total_received_bytes + byte_size(payload) + byte_size("/producer/properties")
    }
  end

  def handle_control(state, "/emptyCache", _payload, message_id, _timestamp) do
    Logger.debug("Received /emptyCache")

    new_state =
      state
      |> send_control_consumer_properties()
      |> resend_all_properties()

    {:ok, db_client} = Database.connect(state.realm)
    :ok = Queries.set_pending_empty_cache(db_client, state.device_id, false)

    MessageTracker.ack_delivery(state.message_tracker, message_id)

    new_state
  end

  def handle_control(state, path, payload, message_id, _timestamp) do
    warn(state, "unexpected control on #{path}, payload: #{inspect(payload)}")

    ask_clean_session(state)
    MessageTracker.discard(state.message_tracker, message_id)

    update_stats(state, "", path, payload)
  end

  def handle_install_volatile_trigger(
        state,
        object_id,
        object_type,
        parent_id,
        trigger_id,
        simple_trigger,
        trigger_target
      ) do
    trigger = SimpleTriggersProtobufUtils.deserialize_simple_trigger(simple_trigger)

    target =
      SimpleTriggersProtobufUtils.deserialize_trigger_target(trigger_target)
      |> Map.put(:simple_trigger_id, trigger_id)
      |> Map.put(:parent_trigger_id, parent_id)

    volatile_triggers_list = [
      {{object_id, object_type}, {trigger, target}} | state.volatile_triggers
    ]

    new_state = Map.put(state, :volatile_triggers, volatile_triggers_list)

    if Map.has_key?(new_state.interface_ids_to_name, object_id) do
      interface_name = Map.get(new_state.interface_ids_to_name, object_id)

      %InterfaceDescriptor{automaton: automaton, aggregation: aggregation} =
        new_state.interfaces[interface_name]

      case trigger do
        {:data_trigger, %ProtobufDataTrigger{match_path: "/*"}} ->
          if aggregation == :individual do
            {:ok, load_trigger(new_state, trigger, target)}
          else
            {{:error, :unsupported_interface_aggregation}, state}
          end

        {:data_trigger, %ProtobufDataTrigger{match_path: match_path}} ->
          with {:ok, _endpoint_id} <- EndpointsAutomaton.resolve_path(match_path, automaton) do
            if aggregation == :individual do
              {:ok, load_trigger(new_state, trigger, target)}
            else
              {{:error, :unsupported_interface_aggregation}, state}
            end
          else
            {:guessed, _} ->
              # State rollback here
              {{:error, :invalid_match_path}, state}

            {:error, :not_found} ->
              # State rollback here
              {{:error, :invalid_match_path}, state}
          end
      end
    else
      case trigger do
        {:data_trigger, %ProtobufDataTrigger{interface_name: "*"}} ->
          {:ok, new_state}

        {:data_trigger,
         %ProtobufDataTrigger{
           interface_name: interface_name,
           interface_major: major,
           match_path: "/*"
         }} ->
          with {:ok, db_client} <- Database.connect(state.realm),
               {:ok, %InterfaceDescriptor{aggregation: :individual}} <-
                 InterfaceQueries.fetch_interface_descriptor(db_client, interface_name, major) do
            {:ok, new_state}
          else
            {:ok, %InterfaceDescriptor{aggregation: :object}} ->
              {{:error, :unsupported_interface_aggregation}, state}

            {:error, reason} ->
              # State rollback here
              {{:error, reason}, state}
          end

        {:data_trigger,
         %ProtobufDataTrigger{
           interface_name: interface_name,
           interface_major: major,
           match_path: match_path
         }} ->
          with {:ok, db_client} <- Database.connect(state.realm),
               {:ok, %InterfaceDescriptor{automaton: automaton, aggregation: :individual}} <-
                 InterfaceQueries.fetch_interface_descriptor(db_client, interface_name, major),
               {:ok, _endpoint_id} <- EndpointsAutomaton.resolve_path(match_path, automaton) do
            {:ok, new_state}
          else
            {:error, :not_found} ->
              # State rollback here
              {{:error, :invalid_match_path}, state}

            {:guessed, _} ->
              # State rollback here
              {{:error, :invalid_match_path}, state}

            {:ok, %InterfaceDescriptor{aggregation: :object}} ->
              {{:error, :unsupported_interface_aggregation}, state}

            {:error, reason} ->
              # State rollback here
              {{:error, reason}, state}
          end

        {:introspection_trigger, _} ->
          {:ok, new_state}

        {:device_trigger, _} ->
          {:ok, new_state}
      end
    end
  end

  def handle_delete_volatile_trigger(state, trigger_id) do
    {new_volatile, maybe_trigger} =
      Enum.reduce(state.volatile_triggers, {[], nil}, fn item, {acc, found} ->
        {_, {_simple_trigger, trigger_target}} = item

        if trigger_target.simple_trigger_id == trigger_id do
          {acc, item}
        else
          {[item | acc], found}
        end
      end)

    case maybe_trigger do
      {{obj_id, obj_type}, {simple_trigger, trigger_target}} ->
        %{state | volatile_triggers: new_volatile}
        |> delete_volatile_trigger({obj_id, obj_type}, {simple_trigger, trigger_target})

      nil ->
        {:ok, state}
    end
  end

  defp delete_volatile_trigger(
         state,
         {obj_id, _obj_type},
         {{:data_trigger, proto_buf_data_trigger}, trigger_target}
       ) do
    if Map.get(state.interface_ids_to_name, obj_id) do
      data_trigger =
        SimpleTriggersProtobufUtils.simple_trigger_to_data_trigger(proto_buf_data_trigger)

      event_type =
        EventTypeUtils.pretty_data_trigger_type(proto_buf_data_trigger.data_trigger_type)

      data_trigger_key = data_trigger_to_key(state, data_trigger, event_type)

      next_data_triggers =
        case Map.get(state.data_triggers, data_trigger_key) do
          [_one_trigger] ->
            Map.delete(state.data_triggers, data_trigger_key)

          nil ->
            state.data_triggers

          triggers_chain ->
            new_chain =
              Enum.reject(triggers_chain, fn chain_target ->
                chain_target == trigger_target
              end)

            Map.put(state.data_triggers, data_trigger_key, new_chain)
        end

      {:ok, %{state | data_triggers: next_data_triggers}}
    else
      {:ok, state}
    end
  end

  defp delete_volatile_trigger(
         state,
         {_obj_id, _obj_type},
         {{:device_trigger, proto_buf_device_trigger}, trigger_target}
       ) do
    event_type =
      EventTypeUtils.pretty_device_event_type(proto_buf_device_trigger.device_event_type)

    device_triggers = state.device_triggers

    updated_targets_list =
      Map.get(device_triggers, event_type, [])
      |> Enum.reject(fn target ->
        target == trigger_target
      end)

    updated_device_triggers = Map.put(device_triggers, event_type, updated_targets_list)

    {:ok, %{state | device_triggers: updated_device_triggers}}
  end

  defp delete_volatile_trigger(
         state,
         {_obj_id, _obj_type},
         {{:introspection_trigger, proto_buf_introspection_trigger}, trigger_target}
       ) do
    introspection_triggers = state.introspection_triggers

    event_type = EventTypeUtils.pretty_change_type(proto_buf_introspection_trigger.change_type)

    introspection_trigger_key =
      {event_type, proto_buf_introspection_trigger.match_interface || :any_interface}

    updated_targets_list =
      Map.get(introspection_triggers, introspection_trigger_key, [])
      |> Enum.reject(fn target ->
        target == trigger_target
      end)

    updated_introspection_triggers =
      Map.put(introspection_triggers, introspection_trigger_key, updated_targets_list)

    {:ok, %{state | introspection_triggers: updated_introspection_triggers}}
  end

  defp reload_device_triggers_on_expiry(state, timestamp, db_client) do
    if state.last_device_triggers_refresh + @device_triggers_lifespan_decimicroseconds <=
         timestamp do
      any_device_id = SimpleTriggersProtobufUtils.any_device_object_id()

      state
      |> Map.put(:last_device_triggers_refresh, timestamp)
      |> Map.put(:device_triggers, %{})
      |> populate_triggers_for_object!(db_client, any_device_id, :any_device)
      |> populate_triggers_for_object!(db_client, state.device_id, :device)
    else
      state
    end
  end

  defp execute_time_based_actions(state, timestamp, db_client) do
    state
    |> Map.put(:last_seen_message, timestamp)
    |> purge_expired_interfaces(timestamp)
    |> reload_device_triggers_on_expiry(timestamp, db_client)
  end

  defp purge_expired_interfaces(state, timestamp) do
    expired =
      Enum.take_while(state.interfaces_by_expiry, fn {expiry, _interface} ->
        expiry <= timestamp
      end)

    new_interfaces_by_expiry = Enum.drop(state.interfaces_by_expiry, length(expired))

    interfaces_to_drop_list =
      for {_exp, iface} <- expired do
        iface
      end

    state
    |> forget_interfaces(interfaces_to_drop_list)
    |> Map.put(:interfaces_by_expiry, new_interfaces_by_expiry)
  end

  defp forget_interfaces(state, []) do
    state
  end

  defp forget_interfaces(state, interfaces_to_drop) do
    iface_ids_to_drop =
      Enum.filter(interfaces_to_drop, &Map.has_key?(state.interfaces, &1))
      |> Enum.map(fn iface ->
        Map.fetch!(state.interfaces, iface).interface_id
      end)

    updated_triggers =
      Enum.reduce(iface_ids_to_drop, state.data_triggers, fn interface_id, data_triggers ->
        Enum.reject(data_triggers, fn {{_event_type, iface_id, _endpoint}, _val} ->
          iface_id == interface_id
        end)
        |> Enum.into(%{})
      end)

    updated_mappings =
      Enum.reduce(iface_ids_to_drop, state.mappings, fn interface_id, mappings ->
        Enum.reject(mappings, fn {_endpoint_id, mapping} ->
          mapping.interface_id == interface_id
        end)
        |> Enum.into(%{})
      end)

    updated_ids =
      Enum.reduce(iface_ids_to_drop, state.interface_ids_to_name, fn interface_id, ids ->
        Map.delete(ids, interface_id)
      end)

    updated_interfaces =
      Enum.reduce(interfaces_to_drop, state.interfaces, fn iface, ifaces ->
        Map.delete(ifaces, iface)
      end)

    %{
      state
      | interfaces: updated_interfaces,
        interface_ids_to_name: updated_ids,
        mappings: updated_mappings,
        data_triggers: updated_triggers
    }
  end

  defp maybe_handle_cache_miss(nil, interface_name, state, db_client) do
    with {:ok, major_version} <-
           DeviceQueries.interface_version(db_client, state.device_id, interface_name),
         {:ok, interface_row} <-
           InterfaceQueries.retrieve_interface_row(db_client, interface_name, major_version),
         %InterfaceDescriptor{} = interface_descriptor <-
           InterfaceDescriptor.from_db_result!(interface_row),
         {:ok, mappings} <-
           Mappings.fetch_interface_mappings_map(db_client, interface_descriptor.interface_id),
         new_interfaces_by_expiry <-
           state.interfaces_by_expiry ++
             [{state.last_seen_message + @interface_lifespan_decimicroseconds, interface_name}],
         new_state <- %State{
           state
           | interfaces: Map.put(state.interfaces, interface_name, interface_descriptor),
             interface_ids_to_name:
               Map.put(
                 state.interface_ids_to_name,
                 interface_descriptor.interface_id,
                 interface_name
               ),
             interfaces_by_expiry: new_interfaces_by_expiry,
             mappings: Map.merge(state.mappings, mappings)
         },
         new_state <-
           populate_triggers_for_object!(
             new_state,
             db_client,
             interface_descriptor.interface_id,
             :interface
           ) do
      # TODO: make everything with-friendly
      {:ok, interface_descriptor, new_state}
    else
      # Known errors. TODO: handle specific cases (e.g. ask for new introspection etc.)
      {:error, :interface_not_in_introspection} ->
        {:error, :interface_loading_failed}

      {:error, :device_not_found} ->
        {:error, :interface_loading_failed}

      {:error, :database_error} ->
        {:error, :interface_loading_failed}

      {:error, :interface_not_found} ->
        {:error, :interface_loading_failed}

      other ->
        Logger.warn("maybe_handle_cache_miss failed: #{inspect(other)}")
        {:error, :interface_loading_failed}
    end
  end

  defp maybe_handle_cache_miss(interface_descriptor, _interface_name, state, _db_client) do
    {:ok, interface_descriptor, state}
  end

  defp prune_device_properties(state, decoded_payload, timestamp) do
    {:ok, paths_set} =
      PayloadsDecoder.parse_device_properties_payload(decoded_payload, state.introspection)

    {:ok, db_client} = Database.connect(state.realm)

    Enum.each(state.introspection, fn {interface, _} ->
      # TODO: check result here
      prune_interface(state, db_client, interface, paths_set, timestamp)
    end)

    :ok
  end

  defp prune_interface(state, db_client, interface, all_paths_set, timestamp) do
    with {:ok, interface_descriptor, new_state} <-
           maybe_handle_cache_miss(
             Map.get(state.interfaces, interface),
             interface,
             state,
             db_client
           ) do
      cond do
        interface_descriptor.type != :properties ->
          # TODO: nobody uses new_state
          {:ok, new_state}

        interface_descriptor.ownership != :device ->
          warn(state, "tried to prune server owned interface: #{interface}.")
          {:error, :maybe_outdated_introspection}

        true ->
          do_prune(new_state, db_client, interface_descriptor, all_paths_set, timestamp)
          # TODO: nobody uses new_state
          {:ok, new_state}
      end
    end
  end

  defp do_prune(state, db, interface_descriptor, all_paths_set, timestamp) do
    each_interface_mapping(state.mappings, interface_descriptor, fn mapping ->
      endpoint_id = mapping.endpoint_id

      Queries.query_all_endpoint_paths!(db, state.device_id, interface_descriptor, endpoint_id)
      |> Enum.each(fn path_row ->
        path = path_row[:path]

        if not MapSet.member?(all_paths_set, {interface_descriptor.name, path}) do
          device_id_string = Device.encode_device_id(state.device_id)

          {:ok, endpoint_id} =
            EndpointsAutomaton.resolve_path(path, interface_descriptor.automaton)

          Queries.delete_property_from_db(state, db, interface_descriptor, endpoint_id, path)

          interface_id = interface_descriptor.interface_id

          path_removed_triggers =
            get_on_data_triggers(state, :on_path_removed, interface_id, endpoint_id, path)

          i_name = interface_descriptor.name

          Enum.each(path_removed_triggers, fn trigger ->
            targets = trigger.trigger_targets

            TriggersHandler.path_removed(
              targets,
              state.realm,
              device_id_string,
              i_name,
              path,
              timestamp
            )
          end)
        end
      end)
    end)
  end

  defp ask_clean_session(%State{realm: realm, device_id: device_id} = state) do
    warn(state, "disconnecting client and asking clean session.")

    encoded_device_id = Device.encode_device_id(device_id)

    {:ok, db_client} = Database.connect(state.realm)

    with :ok <- Queries.set_pending_empty_cache(db_client, device_id, true),
         :ok <- VMQPlugin.disconnect("#{realm}/#{encoded_device_id}", true) do
      :ok
    else
      {:error, reason} ->
        warn(state, "disconnect failed due to error: #{inspect(reason)}")
        # TODO: die gracefully here
        {:error, :clean_session_failed}
    end
  end

  defp get_on_data_triggers(state, event, interface_id, endpoint_id) do
    key = {event, interface_id, endpoint_id}

    Map.get(state.data_triggers, key, [])
  end

  defp get_on_data_triggers(state, event, interface_id, endpoint_id, path, value \\ nil) do
    key = {event, interface_id, endpoint_id}

    candidate_triggers = Map.get(state.data_triggers, key, nil)

    if candidate_triggers do
      ["" | path_tokens] = String.split(path, "/")

      for trigger <- candidate_triggers,
          path_matches?(path_tokens, trigger.path_match_tokens) and
            ValueMatchOperators.value_matches?(
              value,
              trigger.value_match_operator,
              trigger.known_value
            ) do
        trigger
      end
    else
      []
    end
  end

  defp path_matches?([], []) do
    true
  end

  defp path_matches?([path_token | path_tokens], [path_match_token | path_match_tokens]) do
    if path_token == path_match_token or path_match_token == "" do
      path_matches?(path_tokens, path_match_tokens)
    else
      false
    end
  end

  defp populate_triggers_for_object!(state, client, object_id, object_type) do
    object_type_int = SimpleTriggersProtobufUtils.object_type_to_int!(object_type)

    simple_triggers_rows = Queries.query_simple_triggers!(client, object_id, object_type_int)

    new_state =
      Enum.reduce(simple_triggers_rows, state, fn row, state_acc ->
        trigger_id = row[:simple_trigger_id]
        parent_trigger_id = row[:parent_trigger_id]

        simple_trigger =
          SimpleTriggersProtobufUtils.deserialize_simple_trigger(row[:trigger_data])

        trigger_target =
          SimpleTriggersProtobufUtils.deserialize_trigger_target(row[:trigger_target])
          |> Map.put(:simple_trigger_id, trigger_id)
          |> Map.put(:parent_trigger_id, parent_trigger_id)

        load_trigger(state_acc, simple_trigger, trigger_target)
      end)

    Enum.reduce(new_state.volatile_triggers, new_state, fn {{obj_id, obj_type},
                                                            {simple_trigger, trigger_target}},
                                                           state_acc ->
      if obj_id == object_id and obj_type == object_type_int do
        load_trigger(state_acc, simple_trigger, trigger_target)
      else
        state_acc
      end
    end)
  end

  defp data_trigger_to_key(state, data_trigger, event_type) do
    %DataTrigger{
      path_match_tokens: path_match_tokens,
      interface_id: interface_id
    } = data_trigger

    endpoint =
      if path_match_tokens != :any_endpoint and interface_id != :any_interface do
        %InterfaceDescriptor{automaton: automaton} =
          Map.get(state.interfaces, Map.get(state.interface_ids_to_name, interface_id))

        path_no_root =
          path_match_tokens
          |> Enum.map(&replace_empty_token/1)
          |> Enum.join("/")

        {:ok, endpoint_id} = EndpointsAutomaton.resolve_path("/#{path_no_root}", automaton)

        endpoint_id
      else
        :any_endpoint
      end

    {event_type, interface_id, endpoint}
  end

  defp replace_empty_token(token) do
    case token do
      "" ->
        "%{}"

      not_empty ->
        not_empty
    end
  end

  # TODO: implement: on_value_change, on_value_changed, on_path_created, on_value_stored
  defp load_trigger(state, {:data_trigger, proto_buf_data_trigger}, trigger_target) do
    new_data_trigger =
      SimpleTriggersProtobufUtils.simple_trigger_to_data_trigger(proto_buf_data_trigger)

    data_triggers = state.data_triggers

    event_type = EventTypeUtils.pretty_data_trigger_type(proto_buf_data_trigger.data_trigger_type)
    data_trigger_key = data_trigger_to_key(state, new_data_trigger, event_type)
    existing_triggers_for_key = Map.get(data_triggers, data_trigger_key, [])

    # Extract all the targets belonging to the (eventual) existing congruent trigger
    congruent_targets =
      existing_triggers_for_key
      |> Enum.filter(&DataTrigger.are_congruent?(&1, new_data_trigger))
      |> Enum.flat_map(fn congruent_trigger -> congruent_trigger.trigger_targets end)

    new_targets = [trigger_target | congruent_targets]
    new_data_trigger_with_targets = %{new_data_trigger | trigger_targets: new_targets}

    # Replace the (eventual) congruent existing trigger with the new one
    new_data_triggers_for_key = [
      new_data_trigger_with_targets
      | Enum.reject(
          existing_triggers_for_key,
          &DataTrigger.are_congruent?(&1, new_data_trigger_with_targets)
        )
    ]

    next_data_triggers = Map.put(data_triggers, data_trigger_key, new_data_triggers_for_key)
    Map.put(state, :data_triggers, next_data_triggers)
  end

  # TODO: implement on_incoming_introspection, on_interface_minor_updated
  defp load_trigger(
         state,
         {:introspection_trigger, proto_buf_introspection_trigger},
         trigger_target
       ) do
    introspection_triggers = state.introspection_triggers

    event_type = EventTypeUtils.pretty_change_type(proto_buf_introspection_trigger.change_type)

    introspection_trigger_key =
      {event_type, proto_buf_introspection_trigger.match_interface || :any_interface}

    existing_trigger_targets = Map.get(introspection_triggers, introspection_trigger_key, [])

    new_targets = [trigger_target | existing_trigger_targets]

    next_introspection_triggers =
      Map.put(introspection_triggers, introspection_trigger_key, new_targets)

    Map.put(state, :introspection_triggers, next_introspection_triggers)
  end

  # TODO: implement on_empty_cache_received, on_device_error
  defp load_trigger(state, {:device_trigger, proto_buf_device_trigger}, trigger_target) do
    device_triggers = state.device_triggers

    event_type =
      EventTypeUtils.pretty_device_event_type(proto_buf_device_trigger.device_event_type)

    existing_trigger_targets = Map.get(device_triggers, event_type, [])

    new_targets = [trigger_target | existing_trigger_targets]

    next_device_triggers = Map.put(device_triggers, event_type, new_targets)
    Map.put(state, :device_triggers, next_device_triggers)
  end

  defp resolve_path(path, interface_descriptor, mappings) do
    case interface_descriptor.aggregation do
      :individual ->
        with {:ok, endpoint_id} <-
               EndpointsAutomaton.resolve_path(path, interface_descriptor.automaton),
             {:ok, endpoint} <- Map.fetch(mappings, endpoint_id) do
          {:ok, endpoint}
        else
          :error ->
            # Map.fetch failed
            Logger.warn(
              "resolve_path: endpoint_id for path #{inspect(path)} not found in mappings #{
                inspect(mappings)
              }"
            )

            {:error, :mapping_not_found}

          {:error, reason} ->
            Logger.warn("EndpointsAutomaton.resolve_path failed with reason #{inspect(reason)}")
            {:error, :mapping_not_found}

          {:guessed, guessed_endpoints} ->
            {:guessed, guessed_endpoints}
        end

      :object ->
        with {:guessed, guessed_endpoints} <-
               EndpointsAutomaton.resolve_path(path, interface_descriptor.automaton),
             :ok <- check_object_aggregation_prefix(path, guessed_endpoints, mappings) do
          endpoint_id =
            CQLUtils.endpoint_id(
              interface_descriptor.name,
              interface_descriptor.major_version,
              ""
            )

          {:ok, %Mapping{endpoint_id: endpoint_id}}
        else
          {:ok, _endpoint_id} ->
            # This is invalid here, publish doesn't happen on endpoints in object aggregated interfaces
            Logger.warn(
              "Tried to publish on endpoint #{inspect(path)} for object aggregated " <>
                "interface #{inspect(interface_descriptor.name)}. You should publish on " <>
                "the common prefix",
              tag: "invalid_path"
            )

            {:error, :mapping_not_found}

          {:error, :not_found} ->
            Logger.warn(
              "Tried to publish on invalid path #{inspect(path)} for object aggregated " <>
                "interface #{inspect(interface_descriptor.name)}",
              tag: "invalid_path"
            )

            {:error, :mapping_not_found}

          {:error, :invalid_object_aggregation_path} ->
            Logger.warn(
              "Tried to publish on invalid path #{inspect(path)} for object aggregated " <>
                "interface #{inspect(interface_descriptor.name)}",
              tag: "invalid_path"
            )

            {:error, :mapping_not_found}
        end
    end
  end

  defp check_object_aggregation_prefix(path, guessed_endpoints, mappings) do
    received_path_depth = path_or_endpoint_depth(path)

    Enum.reduce_while(guessed_endpoints, :ok, fn
      endpoint_id, _acc ->
        with {:ok, %Mapping{endpoint: endpoint}} <- Map.fetch(mappings, endpoint_id),
             endpoint_depth when received_path_depth == endpoint_depth - 1 <-
               path_or_endpoint_depth(endpoint) do
          {:cont, :ok}
        else
          _ ->
            {:halt, {:error, :invalid_object_aggregation_path}}
        end
    end)
  end

  defp path_or_endpoint_depth(path) when is_binary(path) do
    String.split(path, "/", trim: true)
    |> length()
  end

  defp can_write_on_interface?(interface_descriptor) do
    case interface_descriptor.ownership do
      :device ->
        :ok

      :server ->
        {:error, :cannot_write_on_server_owned_interface}
    end
  end

  defp each_interface_mapping(mappings, interface_descriptor, fun) do
    Enum.each(mappings, fn {_endpoint_id, mapping} ->
      if mapping.interface_id == interface_descriptor.interface_id do
        fun.(mapping)
      end
    end)
  end

  defp reduce_interface_mapping(mappings, interface_descriptor, initial_acc, fun) do
    Enum.reduce(mappings, initial_acc, fn {_endpoint_id, mapping}, acc ->
      if mapping.interface_id == interface_descriptor.interface_id do
        fun.(mapping, acc)
      else
        acc
      end
    end)
  end

  defp send_control_consumer_properties(state) do
    {:ok, db_client} = Database.connect(state.realm)

    Logger.debug(
      "send_control_consumer_properties: device introspection: #{inspect(state.introspection)}"
    )

    abs_paths_list =
      Enum.flat_map(state.introspection, fn {interface, _} ->
        descriptor = Map.get(state.interfaces, interface)

        case maybe_handle_cache_miss(descriptor, interface, state, db_client) do
          {:ok, interface_descriptor, new_state} ->
            gather_interface_properties(new_state, db_client, interface_descriptor)

          {:error, :interface_loading_failed} ->
            warn(state, "resend_all_properties: failed #{interface} interface loading.")
            []
        end
      end)

    send_consumer_properties_payload(state.realm, state.device_id, abs_paths_list)

    state
  end

  defp gather_interface_properties(
         %State{device_id: device_id, mappings: mappings} = _state,
         db_client,
         %InterfaceDescriptor{type: :properties, ownership: :server} = interface_descriptor
       ) do
    reduce_interface_mapping(mappings, interface_descriptor, [], fn mapping, i_acc ->
      Queries.retrieve_endpoint_values(db_client, device_id, interface_descriptor, mapping)
      |> Enum.reduce(i_acc, fn [{:path, path}, {_, _value}], acc ->
        ["#{interface_descriptor.name}#{path}" | acc]
      end)
    end)
  end

  defp gather_interface_properties(_state, _db, %InterfaceDescriptor{} = _descriptor) do
    []
  end

  defp resend_all_properties(state) do
    {:ok, db_client} = Database.connect(state.realm)

    Logger.debug("resend_all_properties. device introspection: #{inspect(state.introspection)}")

    Enum.each(state.introspection, fn {interface, _} ->
      with {:ok, interface_descriptor, new_state} <-
             maybe_handle_cache_miss(
               Map.get(state.interfaces, interface),
               interface,
               state,
               db_client
             ) do
        resend_all_interface_properties(new_state, db_client, interface_descriptor)
      else
        {:error, :interface_loading_failed} ->
          warn(state, "resend_all_properties: failed #{interface} interface loading.")
          {:error, :sending_properties_to_interface_failed}
      end
    end)

    state
  end

  defp resend_all_interface_properties(
         %State{realm: realm, device_id: device_id, mappings: mappings} = _state,
         db_client,
         %InterfaceDescriptor{type: :properties, ownership: :server} = interface_descriptor
       ) do
    encoded_device_id = Device.encode_device_id(device_id)

    each_interface_mapping(mappings, interface_descriptor, fn mapping ->
      Queries.retrieve_endpoint_values(db_client, device_id, interface_descriptor, mapping)
      |> Enum.each(fn [{:path, path}, {_, value}] ->
        {:ok, _} = send_value(realm, encoded_device_id, interface_descriptor.name, path, value)
      end)
    end)
  end

  defp resend_all_interface_properties(_state, _db, %InterfaceDescriptor{} = _descriptor) do
    :ok
  end

  defp send_consumer_properties_payload(realm, device_id, abs_paths_list) do
    topic = "#{realm}/#{Device.encode_device_id(device_id)}/control/consumer/properties"

    uncompressed_payload = Enum.join(abs_paths_list, ";")

    payload_size = byte_size(uncompressed_payload)
    compressed_payload = :zlib.compress(uncompressed_payload)

    payload = <<payload_size::unsigned-big-integer-size(32), compressed_payload::binary>>

    case VMQPlugin.publish(topic, payload, 2) do
      :ok ->
        {:ok, byte_size(topic) + byte_size(payload)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_value(realm, device_id_string, interface_name, path, value) do
    topic = "#{realm}/#{device_id_string}/#{interface_name}#{path}"
    encapsulated_value = %{v: value}

    bson_value = Bson.encode(encapsulated_value)

    Logger.debug("send_value: going to publish #{topic} -> #{inspect(encapsulated_value)}.")

    case VMQPlugin.publish(topic, bson_value, 2) do
      :ok ->
        {:ok, byte_size(topic) + byte_size(bson_value)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def warn(state, msg) do
    Logger.warn("#{state.realm}/#{Device.encode_device_id(state.device_id)}: #{msg}")
  end
end
