defmodule SymphonyElixir.GitHub.Client do
  @moduledoc false

  @spec get_pr(String.t()) :: {:ok, map()} | {:error, term()}
  def get_pr(pr_url) do
    args = ["pr", "view", pr_url, "--json", "state,mergeable,statusCheckRollup,headRefName,baseRefName"]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} ->
            {:ok,
             %{
               state: data["state"],
               mergeable: data["mergeable"],
               checks_status: parse_check_status(data["statusCheckRollup"] || []),
               head_ref: data["headRefName"],
               base_ref: data["baseRefName"]
             }}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {output, code} ->
        {:error, {:gh_error, code, String.trim(output)}}
    end
  end

  @spec merge_pr(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def merge_pr(pr_url, method, delete_branch) do
    args = ["pr", "merge", pr_url, "--#{method}"]
    args = if delete_branch, do: args ++ ["--delete-branch"], else: args

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:gh_merge_failed, code, String.trim(output)}}
    end
  end

  defp parse_check_status([]), do: :no_checks

  defp parse_check_status(checks) do
    cond do
      Enum.any?(checks, &failed_check?/1) -> :failed
      Enum.any?(checks, &pending_check?/1) -> :pending
      true -> :passed
    end
  end

  defp failed_check?(%{"conclusion" => c})
       when c in [
              "FAILURE",
              "CANCELLED",
              "TIMED_OUT",
              "ACTION_REQUIRED",
              "STARTUP_FAILURE",
              "STALE",
              "ERROR"
            ],
       do: true

  defp failed_check?(_), do: false

  defp pending_check?(%{"status" => s}) when s not in ["COMPLETED"], do: true
  defp pending_check?(%{"conclusion" => nil}), do: true
  defp pending_check?(_), do: false
end
