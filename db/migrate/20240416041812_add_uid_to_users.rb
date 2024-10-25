class AddUidToUsers < ActiveRecord::Migration[6.1]
    def up
      add_column :users, :uid, :string, limit: 255
    end
  
    def down
      remove_column :users, :uid, :string, limit: 255
    end
end