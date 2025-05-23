defmodule StreamystatServer.Workers.PlaybackReportingImporter do
  use GenServer
  require Logger
  alias StreamystatServer.Repo
  alias StreamystatServer.Servers.Models.Server
  alias StreamystatServer.Jellyfin.Models.User
  alias StreamystatServer.Jellyfin.Models.Item
  alias StreamystatServer.Sessions.Models.PlaybackSession
  import Ecto.Query

  # Add Timex for better date parsing
  use Timex

  # Batch size for database operations
  @batch_size 50
  # Timeout for DB operations
  @db_timeout 30_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Update to accept file_type parameter
  def import_data(server_id, data, file_type \\ "json") do
    # Log data size before import
    data_size = if is_binary(data), do: String.length(data), else: 0

    # Get a rough activity count for logging
    activity_count =
      cond do
        is_list(data) -> length(data)
        is_binary(data) && file_type == "json" ->
          case Jason.decode(data) do
            {:ok, list} when is_list(list) -> length(list)
            _ -> 0
          end
        is_binary(data) && file_type == "tsv" ->
          data |> String.split("\n") |> length()
        true -> 0
      end

    Logger.info("Starting import of #{activity_count} activities from #{file_type} file (#{data_size} bytes)")

    GenServer.cast(__MODULE__, {:import, server_id, data, file_type})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{importing: false, current_server_id: nil}}
  end

  @impl true
  def handle_cast({:import, server_id, data, file_type}, state) do
    if state.importing do
      Logger.info(
        "Playback Reporting import already in progress for server_id: #{state.current_server_id}, skipping new request for server_id: #{server_id}"
      )

      {:noreply, state}
    else
      data_size = if is_binary(data), do: String.length(data), else: "unknown"

      Logger.info(
        "Starting Playback Reporting import for server_id: #{server_id} with file type: #{file_type}, data size: #{data_size} bytes"
      )

      # Spawn the import process
      task =
        Task.async(fn ->
          Logger.info("Import task started for server_id: #{server_id}")
          result = do_import(server_id, data, file_type)

          Logger.info(
            "Import task completed for server_id: #{server_id} with result: #{inspect(result)}"
          )

          result
        end)

      # Monitor the task for failures
      Process.monitor(task.pid)

      Logger.info("Import task spawned with PID: #{inspect(task.pid)}")
      {:noreply, %{state | importing: true, current_server_id: server_id}}
    end
  end

  @impl true
  def handle_cast({:import_complete, result}, state) do
    server_id = state.current_server_id || "unknown"
    Logger.info(
      "Playback Reporting import completed for server_id: #{server_id}, result: #{inspect(result)}"
    )

    {:noreply, %{state | importing: false, current_server_id: nil}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # We don't care about the DOWN message now, so let's demonitor and flush it
    Process.demonitor(ref, [:flush])
    GenServer.cast(__MODULE__, {:import_complete, result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    case reason do
      :normal ->
        # This is normal termination, no need to log an error
        {:noreply, %{state | importing: false, current_server_id: nil}}
      other_reason ->
        Logger.error("Import task crashed: #{inspect(other_reason)}")
        {:noreply, %{state | importing: false, current_server_id: nil}}
    end
  end

  # Update do_import to handle different file types
  defp do_import(server_id, data, file_type) do
    Logger.debug("Looking up server with ID: #{server_id}")

    try do
      server = Repo.get(Server, server_id)

      if server do
        Logger.info("Found server: #{server.name} (ID: #{server.id})")

        # Process data based on file type
        activities =
          case file_type do
            "json" ->
              decode_json_data(data)

            "tsv" ->
              parse_tsv_data(data)

            _ ->
              Logger.error("Unsupported file type: #{file_type}")
              []
          end

        # Process the data sections
        process_playback_activities_batch(server, activities)
      else
        Logger.error("Server with ID #{server_id} not found")
        {:error, :server_not_found}
      end
    rescue
      e ->
        Logger.error("Error during import: #{inspect(e)}")
        Logger.error(Exception.format_stacktrace())
        {:error, e}
    end
  end

  # Rename the old decode_data to decode_json_data
  defp decode_json_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        # Log the structure to help debug
        Logger.debug("Decoded JSON structure: #{inspect(decoded, pretty: true)}")
        decoded

      {:error, error} ->
        Logger.error("Failed to decode JSON data: #{inspect(error)}")
        []
    end
  end

  defp decode_json_data(data) when is_list(data), do: data
  defp decode_json_data(_), do: []

  # New function to parse TSV data with enhanced logging
  defp parse_tsv_data(data) when is_binary(data) do
    Logger.info("Parsing TSV data (length: #{String.length(data)} bytes)")

    # Log a sample of the data
    sample = if String.length(data) > 500, do: String.slice(data, 0, 500) <> "...", else: data
    Logger.debug("TSV data sample: #{inspect(sample)}")

    # Split the data into lines
    lines = String.split(data, ~r/\r?\n/, trim: true)
    Logger.info("Found #{length(lines)} lines in TSV data")

    # Log the first few lines to help debug the format
    sample_lines = Enum.take(lines, 3)
    Logger.debug("Sample lines: #{inspect(sample_lines)}")

    # Process each line into a map
    parsed_activities =
      Enum.map(lines, fn line ->
        fields = String.split(line, "\t")
        Logger.debug("Line has #{length(fields)} fields: #{inspect(fields)}")

        # Parse TSV format with exactly 9 fields
        case fields do
          [
            date,
            user_id,
            item_id,
            item_type,
            item_name,
            playback_method,
            client_name,
            device_name,
            play_duration
          ] ->
            %{
              "DateCreated" => date,
              "UserId" => user_id,
              "ItemId" => item_id,
              "ItemType" => item_type,
              "ItemName" => item_name,
              "PlaybackMethod" => playback_method,
              "ClientName" => client_name,
              "DeviceName" => device_name,
              "PlayDuration" => play_duration
            }

          _ ->
            Logger.warning("Skipping invalid TSV line: #{line}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Logger.info("Successfully parsed #{length(parsed_activities)} activities from TSV data")

    if parsed_activities == [] do
      Logger.error("No valid activities found in TSV data")
    end

    parsed_activities
  end

  defp parse_tsv_data(_), do: []

  # Process playback activities with batch operations
  defp process_playback_activities_batch(server, activities) when is_list(activities) do
    Logger.info("Processing #{length(activities)} playback activities in batches")

    try do
      # Process in smaller batches to prevent crashes
      results =
        activities
        |> Enum.chunk_every(@batch_size)
        |> Enum.reduce(%{created: 0, updated: 0, skipped: 0, errors: 0}, fn batch, acc ->
          # Add error handling with retry logic around each batch
          case safe_process_batch(server, batch, acc) do
            {:ok, batch_results} ->
              # Combine results from this batch with overall results
              %{
                created: acc.created + batch_results.created,
                updated: acc.updated + batch_results.updated,
                skipped: acc.skipped + batch_results.skipped,
                errors: acc.errors + batch_results.errors
              }

            {:error, _reason} ->
              # Just count the entire batch as errors
              %{acc | errors: acc.errors + length(batch)}
          end
        end)

      Logger.info(
        "Processed #{length(activities)} playback activities: created=#{results.created}, updated=#{results.updated}, skipped=#{results.skipped}, errors=#{results.errors}"
      )

      results
    rescue
      e ->
        Logger.error("Error processing playback activities: #{inspect(e)}")
        %{created: 0, updated: 0, skipped: 0, errors: length(activities)}
    end
  end

  defp process_playback_activities_batch(_, _),
    do: %{created: 0, updated: 0, skipped: 0, errors: 0}

  # Safely load users in a separate transaction
  defp safely_load_users(server) do
    try do
      users_map =
        Repo.transaction(
          fn ->
            users_query =
              from(u in User,
                where: u.server_id == ^server.id,
                select: {u.jellyfin_id, u}
              )

            Repo.all(users_query, timeout: @db_timeout)
          end,
          timeout: @db_timeout
        )

      case users_map do
        {:ok, results} -> {:ok, Map.new(results)}
        error -> error
      end
    rescue
      e ->
        Logger.error("Error loading users: #{inspect(e)}")
        {:error, e}
    end
  end

  # Safely load items in a separate transaction
  defp safely_load_items(server) do
    try do
      items_map =
        Repo.transaction(
          fn ->
            items_query =
              from(i in Item,
                where: i.server_id == ^server.id,
                select: {i.jellyfin_id, i}
              )

            items = Repo.all(items_query, timeout: @db_timeout)
            items
          end,
          timeout: @db_timeout
        )

      case items_map do
        {:ok, results} ->
          map = Map.new(results)
          {:ok, map}
        error ->
          Logger.error("Error in items transaction: #{inspect(error)}")
          error
      end
    rescue
      e ->
        Logger.error("Error loading items: #{inspect(e)}")
        Logger.error(Exception.format_stacktrace())
        {:error, e}
    end
  end

  # Add a new function with retry logic for each batch
  defp safe_process_batch(server, batch, _acc, retry_count \\ 0) do
    # Preload users and items in separate transactions
    with {:ok, users_map} <- safely_load_users(server),
         {:ok, items_map} <- safely_load_items(server) do
      # Process the batch with the loaded maps
      try do
        results = process_playback_batch(server, batch, users_map, items_map)
        {:ok, results}
      rescue
        e in DBConnection.ConnectionError ->
          handle_db_error(e, server, batch, retry_count)

        e ->
          Logger.error("Error processing batch: #{inspect(e, pretty: true)}")
          Logger.error(Exception.format_stacktrace())
          {:error, e}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to preload data: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_db_error(error, server, batch, retry_count) do
    max_retries = 3

    if retry_count < max_retries do
      # Wait a bit before retrying (with exponential backoff)
      backoff = (:math.pow(2, retry_count) * 1000) |> round()

      Logger.warning(
        "Database error, retrying batch in #{backoff}ms (attempt #{retry_count + 1}/#{max_retries}): #{inspect(error.message)}"
      )

      :timer.sleep(backoff)
      safe_process_batch(server, batch, %{}, retry_count + 1)
    else
      Logger.error(
        "Failed to process batch after #{max_retries} attempts: #{inspect(error.message)}"
      )

      {:error, error}
    end
  end

  defp process_playback_batch(server, activities, users_map, items_map) do
    # Create a case-insensitive version of the items map for fallback
    normalized_items_map = Enum.reduce(items_map, %{}, fn {id, item}, acc ->
      Map.put(acc, String.downcase(id), item)
    end)

    # Get the item and user ids directly
    item_ids =
      Enum.map(activities, fn activity ->
        activity["ItemId"]
      end)
      |> Enum.reject(&is_nil/1)

    user_ids =
      Enum.map(activities, fn activity -> activity["UserId"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    # Skip the query if we have no valid IDs
    existing_sessions =
      if Enum.empty?(item_ids) do
        %{}
      else
        # Query for existing sessions in a smaller transaction
        try do
          query_result =
            Repo.transaction(
              fn ->
                existing_query =
                  if Enum.empty?(user_ids) do
                    # Handle anonymous sessions where UserId might be empty
                    from(s in PlaybackSession,
                      where:
                        s.server_id == ^server.id and
                          s.item_jellyfin_id in ^item_ids,
                      select: {s.item_jellyfin_id, s.start_time, s}
                    )
                  else
                    from(s in PlaybackSession,
                      where:
                        s.server_id == ^server.id and
                          s.item_jellyfin_id in ^item_ids and
                          s.user_jellyfin_id in ^user_ids,
                      select: {s.item_jellyfin_id, s.user_jellyfin_id, s.start_time, s}
                    )
                  end

                Repo.all(existing_query, timeout: @db_timeout)
              end,
              timeout: @db_timeout
            )

          case query_result do
            {:ok, existing_sessions_list} ->
              # Convert to map for easier lookup
              session_map = Enum.reduce(existing_sessions_list, %{}, fn
                {item_id, user_id, start_time, session}, acc when is_binary(user_id) ->
                  Map.put(acc, {item_id, user_id, start_time}, session)

                {item_id, start_time, session}, acc ->
                  Map.put(acc, {item_id, start_time}, session)
              end)

              Logger.debug("Found #{map_size(session_map)} existing sessions")
              session_map

            {:error, reason} ->
              Logger.error("Error querying existing sessions: #{inspect(reason)}")
              %{}
          end
        rescue
          e ->
            Logger.error("Error querying existing sessions: #{inspect(e)}")
            Logger.error(Exception.format_stacktrace())
            %{}
        end
      end

    # Process each activity using smaller transactions
    Enum.reduce(activities, %{created: 0, updated: 0, skipped: 0, errors: 0}, fn activity, acc ->
      try do
        activity_id = activity["ItemId"] || "unknown"

        result =
          Repo.transaction(
            fn ->
              create_playback_session_from_report(
                server,
                activity,
                users_map,
                items_map,
                existing_sessions,
                normalized_items_map
              )
            end,
            timeout: @db_timeout
          )

        case result do
          {:ok, {:ok, :created, _}} ->
            Map.update!(acc, :created, &(&1 + 1))
          {:ok, {:ok, :updated, _}} ->
            Map.update!(acc, :updated, &(&1 + 1))
          {:ok, {:skip, _reason}} ->
            Map.update!(acc, :skipped, &(&1 + 1))
          {:ok, {:error, reason}} ->
            Logger.error("Error processing activity for item: #{activity_id}, reason: #{inspect(reason)}")
            Map.update!(acc, :errors, &(&1 + 1))
          {:error, reason} ->
            Logger.error("Transaction error for item: #{activity_id}, reason: #{inspect(reason)}")
            Map.update!(acc, :errors, &(&1 + 1))
        end
      rescue
        e ->
          Logger.error("Exception processing activity: #{inspect(e)}")
          Logger.error(Exception.format_stacktrace())
          Map.update!(acc, :errors, &(&1 + 1))
      end
    end)
  end

  defp create_playback_session_from_report(
         server,
         activity,
         users_map,
         items_map,
         existing_sessions,
         normalized_items_map \\ %{}
       ) do
    try do
      user_jellyfin_id = activity["UserId"]

      user =
        if user_jellyfin_id && user_jellyfin_id != "" do
          Map.get(users_map, user_jellyfin_id)
        else
          nil
        end

      activity_date = parse_date(activity["DateCreated"])

      if is_nil(activity_date) do
        Logger.error("Could not parse date from activity: #{inspect(activity["DateCreated"])}")
        {:error, "Invalid date format"}
      else
        play_duration =
          case activity["PlayDuration"] do
            duration when is_binary(duration) -> String.to_integer(duration)
            duration when is_integer(duration) -> duration
            _ -> 0
          end

        item_jellyfin_id = activity["ItemId"]
        item_name = activity["ItemName"]
        item_type = activity["ItemType"]

        # Try exact match first, then case-insensitive fallback
        item = Map.get(items_map, item_jellyfin_id)

        case_insensitive_item = nil
        if is_nil(item) && !is_nil(item_jellyfin_id) do
          # Try case insensitive lookup as fallback
          normalized_id = String.downcase(item_jellyfin_id)
          case_insensitive_item = Map.get(normalized_items_map, normalized_id)

          if is_nil(case_insensitive_item) do
            Logger.debug("Item not found in database: #{item_jellyfin_id}, name: #{item_name}")
          end
        end

        # Use the case-insensitive match if we have one
        item = item || case_insensitive_item

        # Extract series name from item_name since we need it regardless of whether we have the item
        {series_name, episode_name} = extract_series_info(item_name, item_type)

        # For episodes, use the series name from extraction if item doesn't have it
        series_name =
          if item_type == "Episode" do
            (item && item.series_name) || series_name
          else
            nil
          end

        # Use the actual item name or the extracted episode name for episodes
        actual_item_name =
          if item_type == "Episode" do
            episode_name || item_name
          else
            item_name
          end

        runtime_ticks =
          case item do
            %Item{runtime_ticks: ticks} when not is_nil(ticks) -> ticks
            _ -> 0
          end

        percent_complete =
          if runtime_ticks > 0 do
            # Convert play_duration from seconds to ticks for comparison
            play_duration_ticks = play_duration * 10_000
            # Calculate percentage
            play_duration_ticks / runtime_ticks * 100.0
          else
            # If we don't have runtime_ticks, we can't calculate percentage
            # but we'll still create the session
            0.0
          end

        # Session is considered completed if progress is > 90%
        completed = percent_complete > 90.0

        end_time =
          if activity_date && play_duration && play_duration > 0 do
            DateTime.add(activity_date, play_duration, :second)
          else
            nil
          end

        # Map PlaybackMethod to play_method format
        play_method = map_playback_method(activity["PlaybackMethod"])

        attrs = %{
          user_id: user && user.jellyfin_id,
          user_jellyfin_id: if(user_jellyfin_id == "", do: nil, else: user_jellyfin_id),
          # Not provided in Playback Reporting
          device_id: nil,
          device_name: activity["DeviceName"] || "",
          client_name: activity["ClientName"],
          item_jellyfin_id: item_jellyfin_id,
          item_name: actual_item_name,
          series_jellyfin_id: item && item.series_id,
          series_name: series_name,
          season_jellyfin_id: item && item.season_id,
          play_duration: play_duration,
          play_method: play_method,
          start_time: activity_date,
          end_time: end_time,
          # Not provided in Playback Reporting
          position_ticks: nil,
          runtime_ticks: runtime_ticks,
          percent_complete: percent_complete,
          completed: completed,
          server_id: server.id
        }

        # Check if this session already exists in our lookup map
        existing_key =
          if user_jellyfin_id && user_jellyfin_id != "" do
            {item_jellyfin_id, user_jellyfin_id, activity_date}
          else
            {item_jellyfin_id, activity_date}
          end

        existing_session = Map.get(existing_sessions, existing_key)

        if is_nil(existing_session) do
          result =
            %PlaybackSession{}
            |> PlaybackSession.changeset(attrs)
            |> Repo.insert(timeout: @db_timeout)

          case result do
            {:ok, session} ->
              {:ok, :created, session}

            {:error, changeset} ->
              Logger.error("Failed to create playback session: #{inspect(changeset.errors)}")
              {:error, changeset}
          end
        else
          # Only update if the new data has more information
          if should_update_session?(existing_session, attrs) do
            result =
              existing_session
              |> PlaybackSession.changeset(attrs)
              |> Repo.update(timeout: @db_timeout)

            case result do
              {:ok, session} ->
                {:ok, :updated, session}

              {:error, changeset} ->
                Logger.error("Failed to update playback session: #{inspect(changeset.errors)}")
                {:error, changeset}
            end
          else
            {:skip, "Existing session has better data"}
          end
        end
      end
    rescue
      e ->
        Logger.error("Error in create_playback_session_from_report: #{inspect(e)}")
        Logger.error(Exception.format_stacktrace())
        {:error, "Error: #{inspect(e)}"}
    catch
      kind, reason ->
        Logger.error("Caught #{kind} in create_playback_session_from_report: #{inspect(reason)}")
        Logger.error(Exception.format_stacktrace())
        {:error, "Caught #{kind}: #{inspect(reason)}"}
    end
  end

  # Helper to map Playback Reporting's PlaybackMethod to our format
  defp map_playback_method("DirectPlay"), do: "DirectPlay"
  defp map_playback_method("DirectStream"), do: "DirectStream"

  defp map_playback_method(method) when is_binary(method) do
    cond do
      String.starts_with?(method, "Transcode") -> "Transcode"
      true -> method
    end
  end

  defp map_playback_method(_), do: "Unknown"

  # Extract series name from the item name for TV episodes
  defp extract_series_info(item_name, "Episode") do
    case Regex.run(~r/^(.*?) - s\d+e\d+ - (.*)$/, item_name) do
      [_, series, episode] -> {series, episode}
      _ -> {nil, item_name}
    end
  end

  defp extract_series_info(item_name, _), do: {nil, item_name}

  # Helper functions
  defp should_update_session?(existing, new) do
    # Update if:
    # 1. New session has longer duration
    # 2. New session has more progress
    # 3. New session has more complete data
    new.play_duration > existing.play_duration ||
      (new.position_ticks || 0) > (existing.position_ticks || 0) ||
      (is_nil(existing.end_time) && !is_nil(new.end_time))
  end

  defp parse_date(nil), do: nil

  defp parse_date(date) when is_binary(date) do
    # Try SQL Server datetime format first since it's the most common in our data
    cond do
      # SQL Server datetime format with 7-digit microseconds (as in the example)
      String.match?(date, ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{7}$/) ->
        [year, month, day, hour, minute, second, ms] =
          Regex.run(~r/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{7})$/, date)
          |> tl()

        # Truncate microseconds to 6 digits for ISO compatibility
        ms_truncated = String.slice(ms, 0, 6)
        iso_string = "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{ms_truncated}Z"

        case DateTime.from_iso8601(iso_string) do
          {:ok, dt, _} -> dt
          {:error, _} -> fallback_date_parsing(date)
        end

      # SQL Server datetime format with milliseconds or microseconds
      String.match?(date, ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+$/) ->
        [year, month, day, hour, minute, second, ms] =
          Regex.run(~r/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d+)$/, date)
          |> tl()

        # Ensure ms is 6 digits or less for ISO compatibility
        ms_formatted = String.slice(ms, 0, 6)
        iso_string = "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{ms_formatted}Z"

        case DateTime.from_iso8601(iso_string) do
          {:ok, dt, _} -> dt
          {:error, _} -> fallback_date_parsing(date)
        end

      # SQL Server datetime format without milliseconds
      String.match?(date, ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/) ->
        [year, month, day, hour, minute, second] =
          Regex.run(~r/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/, date)
          |> tl()

        iso_string = "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z"

        case DateTime.from_iso8601(iso_string) do
          {:ok, dt, _} -> dt
          {:error, _} -> fallback_date_parsing(date)
        end

      # Try other formats if the common ones don't match
      true -> fallback_date_parsing(date)
    end
  end

  # Fallback function for other date formats
  defp fallback_date_parsing(date) do
    Logger.debug("Attempting fallback date parsing for: #{date}")

    # Try ISO8601 format
    case DateTime.from_iso8601(date) do
      {:ok, dt, _} -> dt
      {:error, _} ->
        # Try naive datetime
        case NaiveDateTime.from_iso8601(date) do
          {:ok, ndt} ->
            case DateTime.from_naive(ndt, "Etc/UTC") do
              {:ok, dt} -> dt
              {:error, _} -> nil
            end

          {:error, _} ->
            # Try JavaScript Date.toString() format
            js_date_pattern = ~r/^\w{3}\s+\w{3}\s+\d{1,2}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+GMT[-+]\d{4}$/

            if Regex.match?(js_date_pattern, date) do
              try do
                {:ok, dt} = Timex.parse(date, "{WDshort} {Mshort} {D} {YYYY} {h24}:{m}:{s} {Zname}")
                dt
              rescue
                _ -> nil
              end
            else
              # Try Unix timestamp
              case Integer.parse(date) do
                {timestamp, ""} ->
                  timestamp_sec = if timestamp > 100_000_000_000, do: div(timestamp, 1000), else: timestamp
                  DateTime.from_unix!(timestamp_sec)
                _ ->
                  Logger.error("Date format not recognized: #{date}")
                  nil
              end
            end
        end
    end
  end
end
