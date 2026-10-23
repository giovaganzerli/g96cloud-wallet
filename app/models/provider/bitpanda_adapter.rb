class Provider::BitpandaAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BitpandaAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    [ {
      key: "bitpanda", name: "Bitpanda",
      description: I18n.t("bitpanda_items.description"), can_connect: true,
      new_account_path: ->(_type, _return_to) { Rails.application.routes.url_helpers.new_bitpanda_item_path }
    } ]
  end

  def provider_name
    "bitpanda"
  end

  def item
    provider_account.bitpanda_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_bitpanda_item_path(item)
  end

  def institution_name
    "Bitpanda"
  end

  def institution_domain
    "bitpanda.com"
  end

  def institution_url
    "https://www.bitpanda.com"
  end
end
