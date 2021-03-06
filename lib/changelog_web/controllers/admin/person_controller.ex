defmodule ChangelogWeb.Admin.PersonController do
  use ChangelogWeb, :controller

  alias Changelog.{Mailer, Newsletters, Person}
  alias ChangelogWeb.Email
  alias Craisin.Subscriber

  plug :scrub_params, "person" when action in [:create, :update]

  def index(conn, params) do
    page = Person
    |> order_by([p], desc: p.id)
    |> Repo.paginate(params)

    render conn, :index, people: page.entries, page: page
  end

  def new(conn, _params) do
    changeset = Person.admin_changeset(%Person{})
    render conn, "new.html", changeset: changeset
  end

  def create(conn, params = %{"person" => person_params}) do
    changeset = Person.admin_changeset(%Person{}, person_params)

    case Repo.insert(changeset) do
      {:ok, person} ->
        community = Newsletters.community()
        Subscriber.subscribe(community.list_id, person, handle: person.handle)
        handle_welcome_email(person, params)

        conn
        |> put_flash(:result, "success")
        |> smart_redirect(person, params)
      {:error, changeset} ->
        conn
        |> put_flash(:result, "failure")
        |> render("new.html", changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    person = Repo.get!(Person, id)
    changeset = Person.admin_changeset(person)
    render(conn, "edit.html", person: person, changeset: changeset)
  end

  def update(conn, params = %{"id" => id, "person" => person_params}) do
    person = Repo.get!(Person, id)
    changeset = Person.admin_changeset(person, person_params)

    case Repo.update(changeset) do
      {:ok, person} ->
        conn
        |> put_flash(:result, "success")
        |> smart_redirect(person, params)
      {:error, changeset} ->
        conn
        |> put_flash(:result, "failure")
        |> render("edit.html", person: person, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    person = Repo.get!(Person, id)
    Repo.delete!(person)

    conn
    |> put_flash(:result, "success")
    |> redirect(to: admin_person_path(conn, :index))
  end

  defp handle_welcome_email(person, params) do
    case Map.get(params, "welcome") do
      "generic" -> handle_generic_welcome_email(person)
      "guest" -> handle_guest_welcome_email(person)
      _else -> false
    end
  end
  defp handle_generic_welcome_email(person) do
    person = Person.refresh_auth_token(person, 60 * 24)
    Email.welcome(person) |> Mailer.deliver_later
  end
  defp handle_guest_welcome_email(person) do
    person = Person.refresh_auth_token(person, 60 * 24)
    Email.guest_welcome(person) |> Mailer.deliver_later
  end

  defp smart_redirect(conn, _person, %{"close" => _true}) do
    redirect(conn, to: admin_person_path(conn, :index))
  end
  defp smart_redirect(conn, person, _params) do
    redirect(conn, to: admin_person_path(conn, :edit, person))
  end
end
