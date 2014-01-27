class DataPassingSystemSpecController < ApplicationController
  def passing_data_widget
    @foo = 'the_foo'
    @bar = 'and_bar'
  end

  def passing_locals_widget
    render :locals => { :foo => 'local_foo', :bar => 'local_bar' }
  end

  def passing_locals_and_controller_variables_widget
    @foo = "controller_foo"
    @baz = "controller_baz"

    render :locals => { :bar => 'local_bar', :baz => 'local_baz' }
  end

  def omitted_variable
    @foo = 'the_foo'

    render :action => 'passing_data_widget'
  end

  def extra_variables
    @foo = 'the_foo'
    @bar = 'the_bar'

    render :locals => { :baz => 'the_baz' }
  end
end
