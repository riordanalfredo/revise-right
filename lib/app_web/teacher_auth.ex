defmodule AppWeb.TeacherAuth do
  use AppWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias App.Teachers

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in TeacherToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_app_web_teacher_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the teacher in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.
  """
  def log_in_teacher(conn, teacher, params \\ %{}) do
    token = Teachers.generate_teacher_session_token(teacher)
    teacher_return_to = get_session(conn, :teacher_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: teacher_return_to || signed_in_path(conn))
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn) do
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the teacher out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_teacher(conn) do
    teacher_token = get_session(conn, :teacher_token)
    teacher_token && Teachers.delete_teacher_session_token(teacher_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      AppWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the teacher by looking into the session
  and remember me token.
  """
  def fetch_current_teacher(conn, _opts) do
    {teacher_token, conn} = ensure_teacher_token(conn)
    teacher = teacher_token && Teachers.get_teacher_by_session_token(teacher_token)
    assign(conn, :current_teacher, teacher)
  end

  defp ensure_teacher_token(conn) do
    if token = get_session(conn, :teacher_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  @doc """
  Handles mounting and authenticating the current_teacher in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_teacher` - Assigns current_teacher
      to socket assigns based on teacher_token, or nil if
      there's no teacher_token or no matching teacher.

    * `:ensure_authenticated` - Authenticates the teacher from the session,
      and assigns the current_teacher to socket assigns based
      on teacher_token.
      Redirects to login page if there's no logged teacher.

    * `:redirect_if_teacher_is_authenticated` - Authenticates the teacher from the session.
      Redirects to signed_in_path if there's a logged teacher.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_teacher:

      defmodule AppWeb.PageLive do
        use AppWeb, :live_view

        on_mount {AppWeb.TeacherAuth, :mount_current_teacher}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{AppWeb.TeacherAuth, :ensure_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_teacher, _params, session, socket) do
    {:cont, mount_current_teacher(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_teacher(socket, session)

    if socket.assigns.current_teacher do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/teachers/log_in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_teacher_is_authenticated, _params, session, socket) do
    socket = mount_current_teacher(socket, session)

    if socket.assigns.current_teacher do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  defp mount_current_teacher(socket, session) do
    Phoenix.Component.assign_new(socket, :current_teacher, fn ->
      if teacher_token = session["teacher_token"] do
        Teachers.get_teacher_by_session_token(teacher_token)
      end
    end)
  end

  @doc """
  Used for routes that require the teacher to not be authenticated.
  """
  def redirect_if_teacher_is_authenticated(conn, _opts) do
    if conn.assigns[:current_teacher] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the teacher to be authenticated.

  If you want to enforce the teacher email is confirmed before
  they use the application at all, here would be a good place.
  """
  def require_authenticated_teacher(conn, _opts) do
    if conn.assigns[:current_teacher] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/teachers/log_in")
      |> halt()
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:teacher_token, token)
    |> put_session(:live_socket_id, "teachers_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :teacher_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/"
end
