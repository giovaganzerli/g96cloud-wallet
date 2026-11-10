# Renders the modal that picks a custom date range for a chart.
#
# The range is applied as `start_date`/`end_date` query params — the same ones
# a drag across the chart produces — so the picker and the drag-select share
# one code path on the server.
class PeriodRangesController < ApplicationController
  def new
    @target_url = target_url
    @extra_params = extra_params
    @start_date = params[:start_date].presence
    @end_date = params[:end_date].presence
  end

  private
    # The form submits here, so a crafted query must not turn the modal into a
    # redirect to another site: only same-app paths are accepted.
    def target_url
      url = params[:url].to_s
      return root_path unless url.start_with?("/") && !url.start_with?("//")

      url
    end

    # Whatever the picker sent alongside the target path (e.g. the account
    # chart's `chart_view`) rides along in the form as hidden fields.
    def extra_params
      params.except(:controller, :action, :url, :start_date, :end_date, :format, :authenticity_token, :commit)
    end
end
