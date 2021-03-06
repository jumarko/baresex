defmodule Baresex.Event.Register do
  @moduledoc """
  Register event module
  """

  defstruct [:type, :param, :account]

  def new(event) do
    %__MODULE__{type: event["type"], param: event["param"], account: event["accountaor"]}
  end
end
