# frozen_string_literal: true

class PaypalRestApi
  include CurrencyHelper

  PAYPAL_INTENT_CAPTURE = "CAPTURE"
  PAYPAL_CARRIER_OTHER = "OTHER"
  PAYPAL_CARRIER_UNKNOWN = "Unknown"
  NOTE_MAX_LENGTH = 2000
  PAYPAL_MAX_DOCUMENT_SIZE_BYTES = 10.megabytes
  PAYPAL_MAX_TOTAL_UPLOAD_SIZE_BYTES = 50.megabytes
  PAYPAL_ALLOWED_CONTENT_TYPES = %w[image/jpeg image/gif image/png application/pdf].freeze

  GUMROAD_PAYPAL_EVIDENCE_TYPE_MAPPING = {
    receipt_image: "PROOF_OF_RECEIPT_COPY",
    refund_policy_image: "RETURN_POLICY",
    cancellation_policy_image: "RETURN_POLICY", # a cancellation policy is a type of return/terms policy
    customer_communication_file: "PROOF_OF_FULFILLMENT"
  }.freeze

  EVIDENCE_TYPE_PROOF_OF_FULFILLMENT = "PROOF_OF_FULFILLMENT"
  EVIDENCE_TYPE_PROOF_OF_REFUND = "PROOF_OF_REFUND"
  EVIDENCE_TYPE_OTHER = "OTHER"

  def initialize
    paypal_environment = Rails.env.production? ?
                             PayPal::LiveEnvironment.new(PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_CLIENT_SECRET) :
                             PayPal::SandboxEnvironment.new(PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_CLIENT_SECRET)
    @paypal_client = PayPal::PayPalHttpClient.new(paypal_environment)
  end

  def new_request(path:, verb:)
    OpenStruct.new({
                     path:,
                     verb:,
                     headers: rest_api_headers,
                     body: {},
                   })
  end

  def generate_billing_agreement_token(shipping: false)
    @request = new_request(path: "/v1/billing-agreements/agreement-tokens", verb: "POST")
    @request.body = {
      "payer": { "payment_method": "PAYPAL" },
      "plan": {
        "type": "CHANNEL_INITIATED_BILLING",
        "merchant_preferences": {
          "return_url": "#{UrlService.domain_with_protocol}/paypal_ba_return",
          "cancel_url": "#{UrlService.domain_with_protocol}/paypal_ba_cancel",
          "accepted_pymt_type": "INSTANT",
          "skip_shipping_address": !shipping
        }
      }
    }
    execute_request
  end

  def create_billing_agreement(billing_agreement_token_id:)
    @request = new_request(path: "/v1/billing-agreements/agreements", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "create-billing-agreement-#{billing_agreement_token_id}"
    @request.body = {
      "token_id": billing_agreement_token_id
    }
    execute_request
  end

  def create_order(purchase_unit_info:)
    @request = new_request(path: "/v2/checkout/orders", verb: "POST")
    if Rails.env.production? && purchase_unit_info[:invoice_id].present?
      @request.headers["PayPal-Request-Id"] = "create-order-#{purchase_unit_info[:invoice_id]}"
    end
    @request.headers["Prefer"] = "return=representation"
    order_params = {
      intent: PAYPAL_INTENT_CAPTURE,
      purchase_units: [purchase_unit(purchase_unit_info)],
      application_context: { brand_name: "Gumroad", shipping_preference: "NO_SHIPPING" }
    }
    @request.body = order_params
    execute_request
  end

  def update_invoice_id(order_id:, invoice_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "PATCH")
    @request.headers["Prefer"] = "return=representation"
    @request.body = [{ op: "add", path: "/purchase_units/@reference_id=='default'/invoice_id", value: invoice_id }]
    execute_request
  end

  def update_order(order_id:, purchase_unit_info:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "PATCH")
    @request.headers["Prefer"] = "return=representation"
    @request.body = [{ op: "replace", path: "/purchase_units/@reference_id=='default'", value: purchase_unit(purchase_unit_info) }]
    execute_request
  end

  def fetch_order(order_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "GET")
    execute_request
  end

  def capture(order_id:, billing_agreement_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}/capture", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "capture-#{order_id}"
    @request.headers["Prefer"] = "return=representation"
    if billing_agreement_id.present?
      @request.body = {
        "payment_source": {
          "token": {
            "id": billing_agreement_id,
            "type": "BILLING_AGREEMENT"
          }
        }
      }
    end
    execute_request
  end

  def refund(capture_id:, merchant_account: nil, amount: nil)
    paypal_account_id = merchant_account&.charge_processor_merchant_id
    currency = merchant_account&.currency

    # If for some reason we don't have the paypal account id or currency in our records,
    # fetch the original order and get those details from it
    if paypal_account_id.blank? || currency.blank?
      purchase = Purchase.where(stripe_transaction_id: capture_id).last
      raise ArgumentError, "No purchase found for paypal transaction id #{capture_id}" unless purchase.present?

      paypal_order = fetch_order(order_id: purchase.paypal_order_id).result
      if paypal_order.purchase_units.present?
        paypal_account_id ||= paypal_order.purchase_units[0].payee.merchant_id
        currency ||= paypal_order.purchase_units[0].amount.currency_code
      end
    end

    @request = new_request(path: "/v2/payments/captures/#{capture_id}/refund", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "refund-#{capture_id}-#{amount}-#{timestamp}"
    @request.headers["Prefer"] = "return=representation"
    @request.headers["Paypal-Auth-Assertion"] = paypal_auth_assertion_header(paypal_account_id)
    @request.body = refund_body(amount, currency)
    execute_request
  end

  def provide_evidence(dispute_id:, dispute_evidence:)
    base_url = @paypal_client.environment.base_url
    url = "#{base_url}/v1/customer/disputes/#{dispute_id}/provide-evidence"

    evidences = categorically_build_typed_evidence_items(dispute_evidence)

    return OpenStruct.new(status_code: 200, result: { "message" => "No evidence to submit" }) if evidences.empty?

    attached_files = collect_attached_files_for_upload(dispute_evidence)

    input_json = { evidences: evidences }

    payload = { input: input_json.to_json }
    attached_files.each_with_index { |blob, index| payload["file#{index + 1}"] = blob.download }

    response = RestClient.post(url, payload, rest_api_headers)
    OpenStruct.new(status_code: response.code, result: JSON.parse(response.body))
  rescue RestClient::ExceptionWithResponse => e
    # TODO: Consider improving error handling later with notifying via Bugsnag
    Rails.logger.error "PayPal provide-evidence failed: #{e.response.body}"
    raise ChargeProcessorInvalidRequestError.new(e.response.body)
  end

  def successful_response?(api_response)
    (200...300).include?(api_response.status_code)
  end

  private
    def categorically_build_typed_evidence_items(dispute_evidence)
      evidences = []

      fulfillment_evidence = build_fulfillment_based_evidence(dispute_evidence)
      evidences << fulfillment_evidence if fulfillment_evidence.present?

      document_evidences = build_document_based_evidence_items(dispute_evidence)
      evidences.concat(document_evidences)

      refund_evidence = build_refund_based_evidence(dispute_evidence)
      evidences << refund_evidence if refund_evidence.present?

      notes_evidence = build_other_type_based_notes_evidence(dispute_evidence)
      evidences << notes_evidence if notes_evidence.present?

      evidences
    end

    def build_fulfillment_based_evidence(dispute_evidence)
      evidence = { evidence_type: EVIDENCE_TYPE_PROOF_OF_FULFILLMENT }

      if dispute_evidence.shipping_tracking_number.present?
        tracking_info = build_tracking_info(dispute_evidence)
        evidence[:evidence_info] = { tracking_info: [tracking_info] } if tracking_info.present?
      end

      if dispute_evidence.customer_communication_file.attached?
        evidence[:documents] = [{ name: dispute_evidence.customer_communication_file.filename.to_s }]
      end

      has_tracking_info = evidence.key?(:evidence_info)
      has_documents = evidence.key?(:documents)

      evidence if has_tracking_info || has_documents
    end

    def build_document_based_evidence_items(dispute_evidence)
      items = []

      if dispute_evidence.receipt_image.attached?
        items << {
          evidence_type: GUMROAD_PAYPAL_EVIDENCE_TYPE_MAPPING[:receipt_image],
          documents: [{ name: dispute_evidence.receipt_image.filename.to_s }]
        }
      end

      if dispute_evidence.for_subscription_purchase?
        if dispute_evidence.cancellation_policy_image.attached?
          items << {
            evidence_type: GUMROAD_PAYPAL_EVIDENCE_TYPE_MAPPING[:cancellation_policy_image],
            documents: [{ name: dispute_evidence.cancellation_policy_image.filename.to_s }]
          }
        end
      else
        if dispute_evidence.refund_policy_image.attached?
          items << {
            evidence_type: GUMROAD_PAYPAL_EVIDENCE_TYPE_MAPPING[:refund_policy_image],
            documents: [{ name: dispute_evidence.refund_policy_image.filename.to_s }]
          }
        end
      end

      items
    end

    def build_refund_based_evidence(dispute_evidence)
      refund_ids = find_paypal_refund_ids_for_disputed_purchases(dispute_evidence)
      return nil if refund_ids.empty?

      {
        evidence_type: EVIDENCE_TYPE_PROOF_OF_REFUND,
        evidence_info: { refund_ids: refund_ids }
      }
    end

    def find_paypal_refund_ids_for_disputed_purchases(dispute_evidence)
      disputed_purchases = dispute_evidence.dispute.disputable.disputed_purchases

      disputed_purchases.flat_map do |purchase|
        purchase.refunds.filter_map(&:processor_refund_id)
      end.compact.uniq
    end

    def build_other_type_based_notes_evidence(dispute_evidence)
      notes = build_evidence_notes(dispute_evidence)
      return nil if notes.blank?

      {
        evidence_type: EVIDENCE_TYPE_OTHER,
        notes: notes
      }
    end

    def collect_attached_files_for_upload(dispute_evidence)
      candidates = attached_file_candidates(dispute_evidence)

      valid_attachments = []
      total_size = 0

      candidates.each do |attachment|
        unless PAYPAL_ALLOWED_CONTENT_TYPES.include?(attachment.content_type)
          log_skipped_file(dispute_evidence, attachment, "unsupported content type: #{attachment.content_type}")
          next
        end

        if attachment.byte_size > PAYPAL_MAX_DOCUMENT_SIZE_BYTES
          log_skipped_file(dispute_evidence, attachment, "exceeds individual size limit: #{attachment.byte_size} bytes")
          next
        end

        if total_size + attachment.byte_size > PAYPAL_MAX_TOTAL_UPLOAD_SIZE_BYTES
          log_skipped_file(dispute_evidence, attachment, "would exceed total upload limit of #{PAYPAL_MAX_TOTAL_UPLOAD_SIZE_BYTES} bytes")
          next
        end

        valid_attachments << attachment
        total_size += attachment.byte_size
      end

      valid_attachments
    end

    def attached_file_candidates(dispute_evidence)
      candidates = []

      candidates << dispute_evidence.receipt_image if dispute_evidence.receipt_image.attached?

      if dispute_evidence.for_subscription_purchase?
        candidates << dispute_evidence.cancellation_policy_image if dispute_evidence.cancellation_policy_image.attached?
      else
        candidates << dispute_evidence.refund_policy_image if dispute_evidence.refund_policy_image.attached?
      end

      candidates << dispute_evidence.customer_communication_file if dispute_evidence.customer_communication_file.attached?

      candidates
    end

    def log_skipped_file(dispute_evidence, attachment, reason)
      Bugsnag.notify(
        "PayPal provide-evidence: Skipped file '#{attachment.filename}' " \
        "for dispute evidence #{dispute_evidence.id} — #{reason}"
      )
    end

    def purchase_unit(purchase_unit_info)
      currency = purchase_unit_info[:currency]

      info = {
        amount: {
          currency_code: currency,
          value: purchase_unit_info[:total],
          breakdown: {
            shipping: money_object(currency:, value: purchase_unit_info[:shipping]),
            tax_total: money_object(currency:, value: purchase_unit_info[:tax]),
            item_total: money_object(currency:, value: purchase_unit_info[:price])
          }
        },
        payee: {
          merchant_id: purchase_unit_info[:merchant_id]
        },
        items: purchase_unit_info[:items].presence || [
          {
            name: purchase_unit_info[:item_name],
            unit_amount: money_object(currency: purchase_unit_info[:currency], value: purchase_unit_info[:unit_price]),
            quantity: purchase_unit_info[:quantity],
            sku: purchase_unit_info[:product_permalink]
          }
        ],
        soft_descriptor: purchase_unit_info[:descriptor],
        payment_instruction: {
          platform_fees: [
            {
              amount: money_object(currency:, value: purchase_unit_info[:fee]),
              payee: {
                email_address: PAYPAL_PARTNER_EMAIL
              }
            }]
        }
      }

      info[:invoice_id] = purchase_unit_info[:invoice_id] if purchase_unit_info[:invoice_id]

      info
    end

    def refund_body(amount, currency)
      body = {}
      body[:amount] = money_object(currency:, value: amount) if amount.to_f > 0
      body
    end

    def build_evidence_info(dispute_evidence)
      info = {}

      if dispute_evidence.shipping_tracking_number.present?
        tracking_info = build_tracking_info(dispute_evidence)
        info[:tracking_info] = [tracking_info] if tracking_info.present?
      end

      info
    end

    def build_tracking_info(dispute_evidence)
      carrier_mapper = PaypalCarrierMapper.new
      tracking_info = {}

      if dispute_evidence.shipping_carrier.present?
        paypal_carrier_code = carrier_mapper.lookup(dispute_evidence.shipping_carrier)

        if paypal_carrier_code.present?
          tracking_info[:carrier_name] = paypal_carrier_code
        else
          tracking_info[:carrier_name] = PAYPAL_CARRIER_OTHER
          tracking_info[:carrier_name_other] = dispute_evidence.shipping_carrier.truncate(2000)
        end
      else
        tracking_info[:carrier_name] = PAYPAL_CARRIER_OTHER
        tracking_info[:carrier_name_other] = PAYPAL_CARRIER_UNKNOWN
      end

      tracking_info[:tracking_number] = dispute_evidence.shipping_tracking_number

      purchase = dispute_evidence.disputable.purchase_for_dispute_evidence
      calculated_tracking_url = purchase&.shipment&.calculated_tracking_url
      tracking_info[:tracking_url] = calculated_tracking_url if calculated_tracking_url.present?

      tracking_info
    end

    def build_evidence_notes(dispute_evidence)
      notes = []
      notes << "Product: #{dispute_evidence.product_description}" if dispute_evidence.product_description.present?
      notes << "Customer: #{dispute_evidence.customer_name}" if dispute_evidence.customer_name.present?
      notes << "Email: #{dispute_evidence.customer_email}" if dispute_evidence.customer_email.present?
      notes << "IP: #{dispute_evidence.customer_purchase_ip}" if dispute_evidence.customer_purchase_ip.present?
      notes << "Billing address: #{dispute_evidence.billing_address}" if dispute_evidence.billing_address.present?
      notes << "Shipping address: #{dispute_evidence.shipping_address}" if dispute_evidence.shipping_address.present?
      notes << "Reason for winning: #{dispute_evidence.reason_for_winning}" if dispute_evidence.reason_for_winning.present?
      notes << dispute_evidence.uncategorized_text if dispute_evidence.uncategorized_text.present?

      notes.compact.join("\n\n").truncate(NOTE_MAX_LENGTH)
    end

    def timestamp
      Time.current.to_f.to_s.delete(".")
    end

    def rest_api_headers
      {
        "Accept" => "application/json",
        "Accept-Language" => "en_US",
        "Authorization" => PaypalPartnerRestCredentials.new.auth_token,
        "Content-Type" => "application/json",
        "PayPal-Partner-Attribution-Id" => PAYPAL_BN_CODE,
        "PayPal-Request-Id" => timestamp
      }
    end

    def paypal_auth_assertion_header(seller_merchant_id)
      header_part_one = { alg: "none" }.to_json
      header_part_two = { payer_id: seller_merchant_id, iss: PAYPAL_PARTNER_CLIENT_ID }.to_json

      "#{Base64.strict_encode64(header_part_one)}.#{Base64.strict_encode64(header_part_two)}."
    end

    def money_object(currency:, value:)
      { currency_code: currency.upcase, value: }
    end

    def execute_request
      Rails.logger.info "Making Paypal request:: #{LogRedactor.redact(@request)}"
      @paypal_client.execute(@request)
    rescue PayPalHttp::HttpError => e
      Rails.logger.error "Paypal request failed:: Status code: #{e.status_code}, Result: #{e.result.inspect}"
      OpenStruct.new(status_code: e.status_code, result: e.result)
    end
end
