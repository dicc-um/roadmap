class AddProviderToUsers < ActiveRecord::Migration[6.1]
    def up
      add_column :users, :provider, :string, limit: 255
    end
  
    def down
      remove_column :users, :provider, :string, limit: 255
    end
end  