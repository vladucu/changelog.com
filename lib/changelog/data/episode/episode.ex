defmodule Changelog.Episode do
  use Changelog.Data

  alias Changelog.{EpisodeHost, EpisodeGuest, EpisodeTopic, EpisodeStat,
                   EpisodeSponsor, Files, Podcast, Regexp, Transcripts}
  alias ChangelogWeb.{EpisodeView, TimeView}

  schema "episodes" do
    field :slug, :string
    field :guid, :string

    field :title, :string
    field :headline, :string
    field :subheadline, :string

    field :featured, :boolean, default: false
    field :highlight, :string
    field :subhighlight, :string

    field :summary, :string
    field :notes, :string

    field :published, :boolean, default: false
    field :published_at, DateTime
    field :recorded_at, DateTime
    field :recorded_live, :boolean, default: false

    field :audio_file, Files.Audio.Type
    field :bytes, :integer
    field :duration, :integer

    field :download_count, :float
    field :import_count, :float
    field :reach_count, :integer

    field :transcript, {:array, :map}

    belongs_to :podcast, Podcast
    has_many :episode_hosts, EpisodeHost, on_delete: :delete_all
    has_many :hosts, through: [:episode_hosts, :person]
    has_many :episode_guests, EpisodeGuest, on_delete: :delete_all
    has_many :guests, through: [:episode_guests, :person]
    has_many :episode_topics, EpisodeTopic, on_delete: :delete_all
    has_many :topics, through: [:episode_topics, :topic]
    has_many :episode_sponsors, EpisodeSponsor, on_delete: :delete_all
    has_many :sponsors, through: [:episode_sponsors, :sponsor]
    has_many :episode_stats, EpisodeStat

    timestamps()
  end

  def featured(query \\ __MODULE__) do
    from e in query, where: e.featured == true, where: not(is_nil(e.highlight))
  end

  def recorded_live(query \\ __MODULE__) do
    from e in query, where: e.recorded_live == true
  end

  def published(query \\ __MODULE__) do
    from e in query,
      where: e.published == true,
      where: e.published_at <= ^Timex.now
  end

  def scheduled(query \\ __MODULE__) do
    from e in query,
      where: e.published == true,
      where: e.published_at > ^Timex.now
  end

  def unpublished(query \\ __MODULE__) do
    from e in query, where: e.published == false
  end

  def with_numbered_slug(query \\ __MODULE__) do
    from e in query, where: fragment("slug ~ E'^\\\\d+$'")
  end

  def with_slug(query, slug) do
    from e in query, where: e.slug == ^slug
  end

  def with_podcast_slug(query, slug) do
    from e in query, join: p in Podcast, where: e.podcast_id == p.id, where: p.slug == ^slug
  end

  def previous_to(query, episode) do
    from e in query, where: e.published_at < ^episode.published_at
  end

  def next_after(query, episode) do
    from e in query, where: e.published_at > ^episode.published_at
  end

  def recorded_between(query, start_time, end_time) do
    from e in query,
      where: e.recorded_at <= ^start_time,
      where: e.end_time < ^end_time
  end

  def recorded_future_to(query, time) do
    from e in query, where: e.recorded_at > ^time
  end

  def newest_first(query, field \\ :published_at) do
    from e in query, order_by: [desc: ^field]
  end

  def newest_last(query, field \\ :published_at) do
    from e in query, order_by: [asc: ^field]
  end

  def limit(query, count) do
    from e in query, limit: ^count
  end

  def distinct_podcast(query) do
    from e in query, distinct: e.podcast_id
  end

  def search(query, search_term) do
    from e in query,
      where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^search_term)
  end

  def is_public(episode, as_of \\ Timex.now) do
    is_published(episode) && episode.published_at <= as_of
  end

  def is_published(episode) do
    episode.published
  end

  def is_publishable(episode) do
    validated =
      change(episode, %{})
      |> validate_required([:slug, :title, :published_at, :summary, :audio_file])
      |> validate_format(:slug, Regexp.slug, message: Regexp.slug_message)
      |> unique_constraint(:slug, name: :episodes_slug_podcast_id_index)
      |> cast_assoc(:episode_hosts)

    validated.valid? && !is_published(episode)
  end

  def admin_changeset(struct, params \\ %{}) do
    struct
    |> cast(params, ~w(slug title published featured headline subheadline highlight subhighlight summary notes published_at recorded_at recorded_live guid))
    |> cast_attachments(params, ~w(audio_file))
    |> validate_required([:slug, :title, :published, :featured])
    |> validate_format(:slug, Regexp.slug, message: Regexp.slug_message)
    |> validate_featured_has_highlight
    |> validate_published_has_published_at
    |> unique_constraint(:slug, name: :episodes_slug_podcast_id_index)
    |> cast_assoc(:episode_hosts)
    |> cast_assoc(:episode_guests)
    |> cast_assoc(:episode_sponsors)
    |> cast_assoc(:episode_topics)
    |> derive_bytes_and_duration
  end

  def participants(episode) do
    episode =
      episode
      |> preload_guests
      |> preload_hosts

    episode.guests ++ episode.hosts
  end

  def preload_all(episode) do
    episode
    |> preload_podcast
    |> preload_topics
    |> preload_guests
    |> preload_hosts
    |> preload_sponsors
  end

  def preload_topics(episode) do
    episode
    |> Repo.preload(episode_topics: {EpisodeTopic.by_position, :topic})
    |> Repo.preload(:topics)
  end

  def preload_hosts(episode) do
    episode
    |> Repo.preload(episode_hosts: {EpisodeHost.by_position, :person})
    |> Repo.preload(:hosts)
  end

  def preload_guests(episode) do
    episode
    |> Repo.preload(episode_guests: {EpisodeGuest.by_position, :person})
    |> Repo.preload(:guests)
  end

  def preload_podcast(nil), do: nil
  def preload_podcast(episode) do
    episode |> Repo.preload(:podcast)
  end

  def preload_sponsors(episode) do
    episode
    |> Repo.preload(episode_sponsors: {EpisodeSponsor.by_position, :sponsor})
    |> Repo.preload(:sponsors)
  end

  def update_stat_counts(episode) do
    stats = Repo.all(assoc(episode, :episode_stats))

    new_downloads =
      stats
      |> Enum.map(&(&1.downloads))
      |> Enum.sum
      |> Kernel.+(episode.import_count)
      |> Kernel./(1)
      |> Float.round(2)

    new_reach =
      stats
      |> Enum.map(&(&1.uniques))
      |> Enum.sum

    episode
    |> change(%{download_count: new_downloads, reach_count: new_reach})
    |> Repo.update!
  end

  def update_transcript(episode, text) do
    parsed = Transcripts.Parser.parse_text(text, participants(episode))

    episode
    |> change(transcript: parsed)
    |> Repo.update!
  end

  defp derive_bytes_and_duration(changeset) do
    if new_audio_file = get_change(changeset, :audio_file) do
      tagged_file = EpisodeView.audio_local_path(%{changeset.data | audio_file: new_audio_file})

      case File.stat(tagged_file) do
        {:ok, stats} ->
          seconds = extract_duration_seconds(tagged_file)
          change(changeset, bytes: stats.size, duration: seconds)
        {:error, _} -> changeset
      end
    else
      changeset
    end
  end

  defp extract_duration_seconds(path) do
    try do
      {info, _exit_code} = System.cmd("ffmpeg", ["-i", path], stderr_to_stdout: true)
      [_match, duration] = Regex.run ~r/Duration: (.*?),/, info
      TimeView.seconds(duration)
    catch
      _all -> 0
    end
  end

  defp validate_featured_has_highlight(changeset) do
    featured = get_field(changeset, :featured)
    highlight = get_field(changeset, :highlight)

    if featured && is_nil(highlight) do
      add_error(changeset, :highlight, "can't be blank when featured")
    else
      changeset
    end
  end

  defp validate_published_has_published_at(changeset) do
    published = get_field(changeset, :published)
    published_at = get_field(changeset, :published_at)

    if published && is_nil(published_at) do
      add_error(changeset, :published_at, "can't be blank when published")
    else
      changeset
    end
  end
end
