# frozen_string_literal: true

class DisputeEvidence < ApplicationRecord
  def self.create_from_dispute!(dispute)
    DisputeEvidence::CreateFromDisputeService.new(dispute).perform!
  end

  has_paper_trail

  include ExternalId, TimestampStateFields

  delegate :disputable, to: :dispute

  stripped_fields \
    :customer_purchase_ip,
    :customer_email,
    :customer_name,
    :billing_address,
    :product_description,
    :refund_policy_disclosure,
    :cancellation_policy_disclosure,
    :shipping_address,
    :shipping_carrier,
    :shipping_tracking_number,
    :uncategorized_text,
    :cancellation_rebuttal,
    :refund_refusal_explanation,
    :reason_for_winning

  timestamp_state_fields :created, :seller_contacted, :seller_submitted, :resolved

  belongs_to :dispute

  SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS = 72
  MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE = 1_000_000.bytes

  EVIDENCE_LIMITS = {
    "stripe" => {
      max_combined_file_size: 5_000_000,
      allowed_content_types: %w[image/jpeg image/png application/pdf],
      allowed_extensions: %w[jpeg jpg png pdf],
      requires_png_conversion: true
    },
    "paypal" => {
      max_combined_file_size: 50_000_000,
      max_individual_file_size: 10_000_000,
      allowed_content_types: %w[image/jpeg image/gif image/png application/pdf],
      allowed_extensions: %w[jpeg jpg gif png pdf],
      requires_png_conversion: false
    }
  }.freeze

  RESOLUTIONS = %w(unknown submitted rejected).freeze
  RESOLUTIONS.each do |resolution|
    self.const_set("RESOLUTION_#{resolution.upcase}", resolution)
  end

  has_one_attached :cancellation_policy_image
  has_one_attached :refund_policy_image
  has_one_attached :receipt_image
  has_one_attached :customer_communication_file

  validates_presence_of :dispute
  validates :cancellation_rebuttal, :reason_for_winning, :refund_refusal_explanation, length: { maximum: 3_000 }
  validate :customer_communication_file_size
  validate :customer_communication_file_type
  validate :all_files_size_within_limit

  def policy_disclosure=(value)
    policy_disclosure_attribute = for_subscription_purchase? ? :cancellation_policy_disclosure : :refund_policy_disclosure
    self.assign_attributes(policy_disclosure_attribute => value)
  end

  def policy_image
    for_subscription_purchase? ? cancellation_policy_image : refund_policy_image
  end

  def for_subscription_purchase?
    @_subscription_purchase ||= disputable.disputed_purchases.any? { _1.subscription.present? }
  end

  def customer_communication_file_size
    return unless customer_communication_file.attached?
    return if customer_communication_file.byte_size <= customer_communication_file_max_size

    errors.add(:base, "The file exceeds the maximum size allowed.")
  end

  def customer_communication_file_type
    return unless customer_communication_file.attached?
    return if customer_communication_file.content_type.in?(allowed_file_content_types)

    errors.add(:base, "Invalid file type.")
  end

  def processor_evidence_limits
    charge_processor_id = dispute&.purchase&.charge_processor_id
    EVIDENCE_LIMITS[charge_processor_id] || EVIDENCE_LIMITS["stripe"]
  end

  def max_combined_file_size
    processor_evidence_limits[:max_combined_file_size]
  end

  def allowed_file_content_types
    processor_evidence_limits[:allowed_content_types]
  end

  def allowed_file_extensions
    processor_evidence_limits[:allowed_extensions]
  end

  def requires_png_conversion?
    processor_evidence_limits[:requires_png_conversion]
  end

  def hours_left_to_submit_evidence
    return 0 unless seller_contacted?

    (SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - (Time.current - seller_contacted_at) / 1.hour).round
  end

  def all_files_size_within_limit
    all_files_size = receipt_image.byte_size.to_i +
      policy_image.byte_size.to_i +
      customer_communication_file.byte_size.to_i

    return if max_combined_file_size >= all_files_size

    errors.add(:base, "Uploaded files exceed the maximum size allowed.")
  end

  def customer_communication_file_max_size
    @_customer_communication_file_max_size = max_combined_file_size -
      receipt_image.byte_size.to_i -
      policy_image.byte_size.to_i
  end

  def policy_image_max_size
    @_policy_image_max_size = max_combined_file_size -
      MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE -
      receipt_image.byte_size.to_i
  end
end
