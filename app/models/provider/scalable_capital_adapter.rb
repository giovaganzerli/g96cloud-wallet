class Provider::ScalableCapitalAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("ScalableCapitalAccount", self)

  def self.supported_account_types
    %w[Investment]
  end

  def self.connection_configs(family:)
    return [] unless Rails.application.config.app_mode.self_hosted?

    [ {
      key: "scalable_capital", name: "Scalable Capital",
      description: I18n.t("scalable_capital_items.description"), can_connect: true,
      new_account_path: ->(_type, _return_to) { Rails.application.routes.url_helpers.new_scalable_capital_item_path }
    } ]
  end

  def provider_name
    "scalable_capital"
  end

  def item
    provider_account.scalable_capital_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_scalable_capital_item_path(item)
  end

  def institution_name
    "Scalable Capital"
  end

  def institution_domain
    "scalable.capital"
  end

  def institution_url
    "https://scalable.capital"
  end
end
