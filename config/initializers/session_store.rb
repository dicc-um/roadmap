# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

Rails.application.config.session_store :active_record_store, key: '_dmp_roadmap_session',
                                                      same_site: :lax
