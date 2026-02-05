# frozen_string_literal: true

class PaypalCarrierMapper
  CARRIERS_CONFIG_FILE_PATH = Rails.root.join("config", "paypal_carriers.yml")

  def initialize
    @carrier_mapping = load_carrier_mapping
  end

  def lookup(carrier_name)
    return nil if carrier_name.blank?

    normalized_name = carrier_name.to_s.strip

    @carrier_mapping.each do |key, value|
      return value if key.casecmp?(normalized_name)
    end

    nil
  end

  private

  def load_carrier_mapping
    unless File.exist?(CARRIERS_CONFIG_FILE_PATH)
      Rails.logger.error "PayPal carriers config not found at #{CARRIERS_CONFIG_FILE_PATH}"
      return {}
    end

    mapping = YAML.safe_load_file(CARRIERS_CONFIG_FILE_PATH)

    unless mapping.is_a?(Hash)
      Rails.logger.error "Invalid PayPal carriers config format at #{CARRIERS_CONFIG_FILE_PATH}"
      return {}
    end

    mapping
  rescue => e
    Rails.logger.error "Failed to load PayPal carriers config: #{e.message}"
    {}
  end
end
