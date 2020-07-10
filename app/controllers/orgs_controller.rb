# frozen_string_literal: true

class OrgsController < ApplicationController

  include OrgSelectable

  after_action :verify_authorized, except: %w[
    shibboleth_ds shibboleth_ds_passthru search
  ]
  respond_to :html

  # TODO: Refactor this one along with super_admin/orgs_controller. Consider moving
  #       to a new `admin` namespace, leaving public facing actions in here and
  #       moving all of the `admin_` ones to the `admin` namespaced controller

   # TODO: Just use instance variables instead of passing locals. Separating the
  #       create/update will make that easier.
  # GET /org/admin/:id/admin_edit
  def admin_edit
    org = Org.find(params[:id])
    authorize org
    languages = Language.all.order("name")
    org.links = { "org": [] } unless org.links.present?
    render "admin_edit", locals: { org: org, languages: languages, method: "PUT",
                                   url: admin_update_org_path(org) }
  end

  # PUT /org/admin/:id/admin_update
  def admin_update
    attrs = org_params
    @org = Org.find(params[:id])
    authorize @org
    @org.logo = attrs[:logo] if attrs[:logo]
    tab = (attrs[:feedback_enabled].present? ? "feedback" : "profile")
    if attrs[:org_links].present?
      @org.links = ActiveSupport::JSON.decode(attrs[:org_links])
      attrs.delete(:org_links)
    end

    # Only allow super admins to change the org types and shib info
    if current_user.can_super_admin?
      identifiers = []
      attrs[:managed] = attrs[:managed] == "1"

      # Handle Shibboleth identifier if that is enabled
      if Rails.configuration.x.shibboleth.use_filtered_discovery_service
        shib = IdentifierScheme.by_name("shibboleth").first

        if shib.present? && attrs.fetch(:identifiers_attributes, []).any?
          entity_id = attrs[:identifiers_attributes].first[:value]
          identifier = Identifier.find_or_initialize_by(
            identifiable: @org, identifier_scheme: shib, value: entity_id
          )
          @org = process_identifier_change(org: @org, identifier: identifier)
        end
        attrs.delete(:identifiers_attributes)
      end

      attrs[:managed] = attrs[:managed] == "1"

      # See if the user selected a new Org via the Org Lookup and
      # convert it into an Org
      lookup = org_from_params(params_in: attrs)
      ids = identifiers_from_params(params_in: attrs)
      identifiers += ids.select { |id| id.value.present? }
    end

    # Remove the extraneous Org Selector hidden fields
    attrs = remove_org_selection_params(params_in: attrs)

    if @org.update(attrs)
      # Save any identifiers that were found
      if current_user.can_super_admin? && lookup.present?
        # Loop through the identifiers and then replace the existing
        # identifier and save the new one
        identifiers.each do |id|
          @org = process_identifier_change(org: @org, identifier: id)
        end
        @org.save
      end

      redirect_to "#{admin_edit_org_path(@org)}\##{tab}",
                  notice: success_message(@org, _("saved"))
    else
      failure = failure_message(@org, _("save")) if failure.blank?
      redirect_to "#{admin_edit_org_path(@org)}\##{tab}", alert: failure
    end
  end

  # This action is used by installations that have the following config enabled:
  #   Rails.configuration.x.shibboleth.use_filtered_discovery_service
  def shibboleth_ds
    redirect_to root_path unless current_user.nil?

    @user = User.new
    # Display the custom Shibboleth discovery service page.
    @orgs = Identifier.by_scheme_name("shibboleth", "Org")
                      .sort { |a, b| a.identifiable.name <=> b.identifiable.name }

    if @orgs.empty?
      flash.now[:alert] = _("No organisations are currently registered.")
      redirect_to user_shibboleth_omniauth_authorize_path
    end
  end

  # This action is used to redirect a user to the Shibboleth IdP
  # POST /orgs/shibboleth_ds
  def shibboleth_ds_passthru
    if !shib_params["shib-ds"][:org_name].blank?
      session["org_id"] = shib_params["shib-ds"][:org_name]

      org = Org.where(id: shib_params["shib-ds"][:org_id])
      shib_entity = Identifier.by_scheme_name("shibboleth", "Org")
                              .where(identifiable: org)

      if !shib_entity.empty?
        # initiate shibboleth login sequence
        entity_param = "entityID=#{shib_entity.first.value}"
        redirect_to "#{shib_login_url}?#{shib_callback_url}&#{entity_param}"
      else
        failure = _("Your organisation does not seem to be properly configured.")
        redirect_to shibboleth_ds_path, alert: failure
      end

    else
      redirect_to shibboleth_ds_path, notice: _("Please choose an organisation")
    end
  end

  # POST /orgs  (via AJAX from OrgSelectiors)
  def search
    args = search_params
    # If the search term is greater than 2 characters
    if args.present? && args.fetch(:name, "").length > 2
      type = args.fetch(:type, "local")

      # If we are including external API results
      case type
      when "combined"
        orgs = OrgSelection::SearchService.search_combined(
          search_term: args[:name]
        )
      when "external"
        orgs = OrgSelection::SearchService.search_externally(
          search_term: args[:name]
        )
      else
        orgs = OrgSelection::SearchService.search_locally(
          search_term: args[:name]
        )
      end

      # If we need to restrict the results to funding orgs then
      # only return the ones with a valid fundref
      if orgs.present? && args.fetch(:funder_only, "false") == true
        orgs = orgs.select do |org|
          org[:fundref].present? && !org[:fundref].blank?
        end
      end

      render json: orgs

    else
      render json: []
    end
  end

  private

  def org_params
    params.require(:org)
          .permit(:name, :abbreviation, :logo, :contact_email, :contact_name,
                  :remove_logo, :org_type, :managed, :feedback_enabled, :org_links,
                  :feedback_email_msg, :org_id, :org_name, :org_crosswalk,
                  identifiers_attributes: %i[identifier_scheme_id value],
                  tracker_attributes: %i[code])
  end

  def shib_params
    params.permit("shib-ds": %i[org_id org_name])
  end

  def search_params
    params.require(:org).permit(:name, :type)
  end

  def shib_login_url
    shib_login = Rails.configuration.x.shibboleth.login_url
    "#{request.base_url.gsub('http:', 'https:')}#{shib_login}"
  end

  def shib_callback_url
    "target=#{user_shibboleth_omniauth_callback_url.gsub('http:', 'https:')}"
  end

  # Destroy the identifier if it exists and was blanked out, replace the
  # identifier if it was updated, create the identifier if its new, or
  # ignore it
  def process_identifier_change(org:, identifier:)
    return org unless identifier.is_a?(Identifier)

    if !identifier.new_record? && identifier.value.blank?
      # Remove the identifier if it has been blanked out
      identifier.destroy
    elsif identifier.value.present?
      # If the identifier already exists then remove it
      current = org.identifier_for_scheme(scheme: identifier.identifier_scheme)
      current.destroy if current.present? && current.value != identifier.value

      identifier.identifiable = org
      org.identifiers << identifier
    end

    org
  end

end
