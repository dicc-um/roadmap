class ChangeSessionsSessionIdStringLimit < ActiveRecord::Migration[6.1]
    def up
      change_column :sessions, :session_id, :string, limit:255
    end
    def down
      change_column :sessions, :session_id, :string, limit: 64
    end
end