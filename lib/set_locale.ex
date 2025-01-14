defmodule SetLocale do
  import Plug.Conn

  defmodule Config do
    defstruct gettext: nil, default_locale: nil, cookie_key: nil
  end

  def init(gettext: gettext, default_locale: default_locale, cookie_key: cookie_key) do
    %Config{gettext: gettext, default_locale: default_locale, cookie_key: cookie_key}
  end
  def init(gettext: gettext, default_locale: default_locale) do
    %Config{gettext: gettext, default_locale: default_locale, cookie_key: nil}
  end
  def init([gettext, default_locale]) do
    unless Mix.env == :test do
      IO.warn ~S(
        This config style has been deprecated for for set_locale. Please update the old style config:
        plug SetLocale, [MyApp.Gettext, "en-gb"]

        to the new config:
        plug SetLocale, gettext: MyApp.Gettext, default_locale: "en-gb", cookie_key: "preferred_locale"]
      ), Macro.Env.stacktrace(__ENV__)
    end
    %Config{gettext: gettext, default_locale: default_locale, cookie_key: nil}
  end

  def call(%{ params: %{ "locale" => requested_locale } } = conn, config ) do
    if supported_locale?(requested_locale, config) do
      assign_locale(conn, config, requested_locale)
    else
      get_locale_from_cookie(conn, config)
      |> handle_unknown_locale(conn, config)
    end
  end

  def call(%{ assigns: %{ locale: requested_locale } } = conn, config) do
    assign_locale(conn, config, requested_locale)
  end

  def call(conn, config) do
    locale = determine_locale(conn, nil, config)

    assign_locale(conn, config, locale)
  end

  defp handle_unknown_locale(nil, conn, config) do
    assign_locale(conn, config, config.default_locale)
  end

  defp handle_unknown_locale(locale, conn, config) do
    if locale != config.default_locale do
      path = rewrite_path(conn, locale, config)

      conn
      |> redirect_to(path)
      |> halt
    else
      assign_locale(conn, config, locale)
    end
  end

  defp assign_locale(conn, config, locale) do
    Gettext.put_locale(config.gettext, locale)
    put_locale_into_cookie(conn, config, locale) |> assign(:locale, locale)
  end

  defp rewrite_path(%{request_path: request_path} = conn, requested_locale, config) do
    locale = determine_locale(conn, requested_locale, config)

    request_path
    |> maybe_strip_unsupported_locale
    |> localize_path(locale)
  end

  defp determine_locale(conn, nil, config) do
    determined_locale =
      get_locale_from_cookie(conn, config)
      || get_locale_from_http_referrer(conn)
      || get_locale_from_header(conn, config)

    if supported_locale?(determined_locale, config),
      do: determined_locale,
      else: config.default_locale
  end

  defp determine_locale(conn, requested_locale, config) do
    base = hd String.split(requested_locale, "-")

    if (is_locale?(requested_locale) and supported_locale?(base, config)) do
      base
    else
      determine_locale(conn, nil, config)
    end
  end

  # Attempt to extract a locale from the HTTP "referer" header.
  # If that url exists and had a language prefix, it's a good indication of what locale the user prefers.
  # And yes, it is referer, not referrer. A typo in the original HTTP spec means it will haunt us forever.
  defp get_locale_from_http_referrer(conn) do
    conn
    |> get_req_header("referer")
    |> case do
         [referrer] when is_binary(referrer) ->
           uri = URI.parse(referrer)
           maybe_extract_locale(uri.path)
         _ ->
           nil
       end
  end

  defp supported_locales(config), do: Gettext.known_locales(config.gettext)

  defp maybe_strip_unsupported_locale(request_path) do
    maybe_locale = maybe_extract_locale(request_path)
    if maybe_locale, do: strip_unsupported_locale(request_path), else: request_path
  end

  defp maybe_extract_locale(request_path) when is_binary(request_path) do
    case String.split(request_path, "/") do
      [_, maybe_locale | _] ->
        if is_locale?(maybe_locale), do: maybe_locale, else: nil
      _ -> nil
    end
  end
  defp maybe_extract_locale(_), do: nil

  defp is_locale?(maybe_locale), do: Regex.match?(~r/^[a-z]{2}(-[a-z]{2})?$/, maybe_locale)

  defp strip_unsupported_locale(request_path) do
    [_, _ | rest] = String.split(request_path, "/")
    "/" <> Enum.join(rest, "/")
  end

  defp localize_path("/", locale), do: "/#{locale}"
  defp localize_path(request_path, locale), do: "/#{locale}#{request_path}"

  defp redirect_to(conn, path) do
    path = get_redirect_path(conn, path)
    Phoenix.Controller.redirect(conn, to: path)
  end

  defp get_redirect_path(%{query_string: query_string}, path) when query_string != "", do: path <> "?#{query_string}"
  defp get_redirect_path(_conn, path), do: path

  defp get_locale_from_cookie(conn, config), do: Plug.Conn.get_session(conn, config.cookie_key)

  defp put_locale_into_cookie(conn, config, locale) do
    put_session(conn, config.cookie_key, locale)
  end

  defp get_locale_from_header(conn, gettext) do
    conn
    |> SetLocale.Headers.extract_accept_language
    |> Enum.find(nil, fn accepted_locale -> supported_locale?(accepted_locale, gettext) end)
  end

  defp supported_locale?(locale, config), do: Enum.member?(supported_locales(config), locale)
end
