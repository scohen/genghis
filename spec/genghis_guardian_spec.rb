require 'spec_helper'
require 'mongo'


describe Genghis::Guardian do
  include Mongo
  class Orig
    def foo
    end
  end

  class Protected < Genghis::Guardian;
    protects Orig
  end

  before(:each) do
    Protected.protects Orig
  end

  context "when protecting an object" do
    before do
      set_yaml_file('test' =>
                        {'server'             => 'mongodb://localhost',
                         'connection_options' => {'max_retries' => 2}})
      Genghis.environment = :test
      Genghis.max_retries = 2
      Genghis.max_retries.should == 2
      Genghis.sleep_between_retries = 0
      @protected         = Protected.new
    end

    it "should be able to reveal the protected object" do
      @protected.unprotected_object.should be_kind_of(Orig)
    end

    it 'should have Orig as a protected class' do
      Genghis::Guardian.protected_classes.should include(Orig)
      Genghis::Guardian.should be_under_protection(Orig)
      Genghis::Guardian.should be_protecting(Orig)
    end

    it "shouldn't have string as a protected class" do
      Genghis::Guardian.protected_classes.should_not include(String)
      Genghis::Guardian.should_not be_under_protection(String)
      Genghis::Guardian.should_not be_protecting(String)
    end


    context "when returning a value under protection" do
      before do
        @protected.unprotected_object.should_receive(:foo).and_return(Orig.new)
        @foo = @protected.foo
      end


      it "should be safe" do
        # had to do this because of some peculiarity between rspec and the proxy
        @foo.safe?.should == true
      end

      context "and it is an array of protected objects" do
        before do
          @protected.unprotected_object.should_receive(:foo).and_return([Orig.new])
          @rv = @protected.foo
        end

        it "should be an array proxy" do
          @rv.safe?.should == true
          @rv[0].safe?.should == true
        end
      end
    end


    context "and the connection fails" do

      it "should protect against a connection failure" do
        @protected.unprotected_object.should_receive(:foo).once.and_raise(Mongo::ConnectionFailure)
        @protected.unprotected_object.should_receive(:foo).once.and_return('hi')
        lambda { @protected.foo }.should_not raise_error(Mongo::ConnectionFailure)
      end

      it "should let non connection exceptions through" do
        @protected.unprotected_object.should_receive(:foo).and_raise("This sucks")
        lambda { @protected.foo }.should raise_error
      end

      context "when retrying" do
        it "should retry to connect max_retries number of times" do
          @protected.unprotected_object.should_receive(:foo).exactly(2).times.and_raise(Mongo::ConnectionFailure)
          @protected.unprotected_object.should_receive(:foo).once.and_return('yay')
          @protected.unprotected_object.should_receive(:foo).any_number_of_times.and_raise(Mongo::ConnectionFailure)
          lambda { @protected.foo }.should_not raise_error(Mongo::ConnectionFailure)
          lambda { @protected.foo }.should raise_error(Mongo::ConnectionFailure)
        end

        context "when on_failure is set" do
          before do
            @connection = nil
            @exception  = nil
            Genghis.on_failure { |ex, conn| @connection = conn; @exception = ex }
          end

          it "should execute the on_failure handler" do
            calls = Genghis.max_retries + 1
            @protected.unprotected_object.should_receive(:foo).exactly(calls).times.and_raise(Mongo::ConnectionFailure)
            lambda { calls.times { @protected.foo } }.should raise_error(Mongo::ConnectionFailure)
            @connection.should_not be_nil
            @exception.should_not be_nil
          end

        end

      end

    end
  end


end