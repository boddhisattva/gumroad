# frozen_string_literal: true

require "spec_helper"

describe PaypalCarrierMapper do
  subject { described_class.new }

  describe "#lookup" do
    context "when carrier is recognized" do
      it "returns PayPal enum for exact match" do
        expect(subject.lookup("UPS")).to eq("UPS")
        expect(subject.lookup("USPS")).to eq("USPS")
        expect(subject.lookup("FedEx")).to eq("FEDEX")
        expect(subject.lookup("DHL")).to eq("DHL")
      end

      it "returns PayPal enum for case-insensitive match" do
        expect(subject.lookup("ups")).to eq("UPS")
        expect(subject.lookup("fedex")).to eq("FEDEX")
        expect(subject.lookup("FEDEX")).to eq("FEDEX")
        expect(subject.lookup("FeDex")).to eq("FEDEX")
      end

      it "returns PayPal enum for carriers with spaces" do
        expect(subject.lookup("Royal Mail")).to eq("ROYAL_MAIL")
        expect(subject.lookup("Canada Post")).to eq("CA_CANADA_POST")
        expect(subject.lookup("Star Track")).to eq("STARTRACK")
      end

      it "handles leading/trailing whitespace" do
        expect(subject.lookup("  UPS  ")).to eq("UPS")
        expect(subject.lookup("\tFedEx\n")).to eq("FEDEX")
      end

      it "returns PayPal enum for full carrier names" do
        expect(subject.lookup("United Parcel Service")).to eq("UPS")
        expect(subject.lookup("Federal Express")).to eq("FEDEX")
        expect(subject.lookup("United States Postal Service")).to eq("USPS")
      end

      it "maps regional variants correctly" do
        expect(subject.lookup("UPS UK")).to eq("UK_UPS")
        expect(subject.lookup("FedEx Germany")).to eq("DE_FEDEX")
        expect(subject.lookup("FedEx France")).to eq("FR_FEDEX")
      end

      it "maps carriers from Shipment::CARRIER_TRACKING_URL_MAPPING" do
        # These are the 7 carriers already known in Gumroad's system
        expect(subject.lookup("USPS")).to eq("USPS")
        expect(subject.lookup("UPS")).to eq("UPS")
        expect(subject.lookup("FedEx")).to eq("FEDEX")
        expect(subject.lookup("DHL")).to eq("DHL")
        expect(subject.lookup("OnTrac")).to eq("ONTRAC")
        expect(subject.lookup("Canada Post")).to eq("CA_CANADA_POST")
      end
    end

    context "when carrier is not recognized" do
      it "returns nil for unknown carrier" do
        expect(subject.lookup("Unknown Carrier")).to be_nil
        expect(subject.lookup("My Custom Carrier")).to be_nil
        expect(subject.lookup("XYZ Delivery")).to be_nil
      end

      it "returns nil for blank input" do
        expect(subject.lookup(nil)).to be_nil
        expect(subject.lookup("")).to be_nil
        expect(subject.lookup("  ")).to be_nil
      end
    end

    context "with edge cases" do
      it "handles special characters in carrier names" do
        expect(subject.lookup("Pošta")).to be_nil  # Not in mapping
      end

      it "handles numeric input" do
        expect(subject.lookup(123)).to be_nil
      end
    end
  end

  describe "config file loading" do
    it "loads carriers from YAML file" do
      expect(File).to exist(PaypalCarrierMapper::CARRIERS_CONFIG_FILE_PATH)
    end

    context "when config file is missing" do
      it "handles gracefully and logs error" do
        allow(File).to receive(:exist?).and_return(false)
        expect(Rails.logger).to receive(:error).with(/config not found/)

        mapper = described_class.new
        expect(mapper.lookup("UPS")).to be_nil
      end
    end

    context "when config file is invalid" do
      it "handles gracefully and logs error" do
        allow(YAML).to receive(:safe_load_file).and_return("invalid")
        expect(Rails.logger).to receive(:error).with(/Invalid.*format/)

        mapper = described_class.new
        expect(mapper.lookup("UPS")).to be_nil
      end
    end

    context "when config file raises exception" do
      it "handles gracefully and logs error" do
        allow(YAML).to receive(:safe_load_file).and_raise(StandardError.new("Test error"))
        expect(Rails.logger).to receive(:error).with(/Failed to load.*Test error/)

        mapper = described_class.new
        expect(mapper.lookup("UPS")).to be_nil
      end
    end
  end
end
