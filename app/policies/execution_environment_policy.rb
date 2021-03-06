class ExecutionEnvironmentPolicy < AdminOrAuthorPolicy
  def author?
    @user == @record.author
  end
  private :author?

  [:execute_command?, :shell?].each do |action|
    define_method(action) { admin? || author? }
  end
end
