require "test/unit"
require "pkcs11"
require "test/helper"
require "openssl"

class TestPkcs11Crypt < Test::Unit::TestCase
  include PKCS11

  attr_reader :slots
  attr_reader :slot
  attr_reader :session
  attr_reader :rsa_priv_key
  attr_reader :rsa_pub_key
  attr_reader :secret_key

  def setup
    $pkcs11 ||= open_softokn
    @slots = pk.active_slots
    @slot = slots.last
    
    flags = CKF_SERIAL_SESSION #| CKF_RW_SESSION
    @session = slot.open(flags)
    session.login(:USER, "")
    
    @rsa_pub_key = session.find_objects(:CLASS => CKO_PUBLIC_KEY,
                        :KEY_TYPE => CKK_RSA).first
    @rsa_priv_key = session.find_objects(:CLASS => CKO_PRIVATE_KEY,
                        :KEY_TYPE => CKK_RSA).first
    @secret_key = session.create_object(
      :CLASS=>CKO_SECRET_KEY,
      :KEY_TYPE=>CKK_DES2,
      :ENCRYPT=>true, :WRAP=>true, :DECRYPT=>true, :UNWRAP=>true, :TOKEN=>false,
      :VALUE=>'0123456789abcdef',
      :LABEL=>'test_secret_key')
  end

  def teardown
    @secret_key.destroy
    @session.logout
    @session.close
  end

  def pk
    $pkcs11
  end

  def test_endecrypt
    plaintext1 = "secret text"
    cryptogram = session.encrypt( :RSA_PKCS, rsa_pub_key, plaintext1)
    assert cryptogram.length>10, 'The cryptogram should contain some data'
    assert_not_equal cryptogram, plaintext1, 'The cryptogram should be different to plaintext'
    
    plaintext2 = session.decrypt( :RSA_PKCS, rsa_priv_key, cryptogram)
    assert_equal plaintext1, plaintext2, 'Decrypted plaintext should be the same'
  end

  def test_sign_verify
    plaintext = "important text"
    signature = session.sign( :SHA1_RSA_PKCS, rsa_priv_key, plaintext)
    assert signature.length>10, 'The signature should contain some data'

    signature2 = session.sign( :SHA1_RSA_PKCS, rsa_priv_key){|c|
      c.update(plaintext[0..3])
      c.update(plaintext[4..-1])
    }
    assert_equal signature, signature2, 'results of one-step and two-step signatures should be equal'

    valid = session.verify( :SHA1_RSA_PKCS, rsa_pub_key, signature, plaintext)
    assert  valid, 'The signature should be correct'
    
    assert_raise(PKCS11::Error, 'The signature should be invalid on different text') do
      session.verify( :SHA1_RSA_PKCS, rsa_pub_key, signature, "modified text")
    end
  end

  def create_openssl_cipher(pk11_key)
    rsa = OpenSSL::PKey::RSA.new
    rsa.n = OpenSSL::BN.new pk11_key[:MODULUS], 2
    rsa.e = OpenSSL::BN.new pk11_key[:PUBLIC_EXPONENT], 2
    rsa
  end

  def test_compare_sign_with_openssl
    signature = session.sign( :SHA1_RSA_PKCS, rsa_priv_key, "important text")

    osslc = create_openssl_cipher rsa_pub_key
    valid = osslc.verify(OpenSSL::Digest::SHA1.new, signature, "important text")
    assert valid, 'The signature should be correct'
  end

  def test_compare_endecrypt_with_openssl
    plaintext1 = "secret text"
    osslc = create_openssl_cipher rsa_pub_key
    cryptogram = osslc.public_encrypt(plaintext1)

    plaintext2 = session.decrypt( :RSA_PKCS, rsa_priv_key, cryptogram)
    assert_equal plaintext1, plaintext2, 'Decrypted plaintext should be the same'
  end

  def test_digest
    plaintext = "secret text"
    digest1 = session.digest( :SHA_1, plaintext)
    digest2 = OpenSSL::Digest::SHA1.new(plaintext).digest
    assert_equal digest1, digest2, 'Digests should be equal'
    digest3 = session.digest(:SHA_1){|c|
      c.update(plaintext[0..3])
      c.update(plaintext[4..-1])
    }
    assert_equal digest1, digest3, 'Digests should be equal'

    digest3 = session.digest(:SHA256){|c|
      c.update(plaintext)
      c.digest_key(secret_key)
    }
  end

  def test_wrap_key
    wrapped_key_value = session.wrap_key(:DES3_ECB, secret_key, secret_key)
    assert_equal 16, wrapped_key_value.length, '112 bit 3DES key should have same size wrapped'

    unwrapped_key = session.unwrap_key(:DES3_ECB, secret_key, wrapped_key_value, :CLASS=>CKO_SECRET_KEY, :KEY_TYPE=>CKK_DES2, :ENCRYPT=>true, :DECRYPT=>true)

    secret_key_kcv = session.encrypt( :DES3_ECB, secret_key, "\0"*8)
    unwrapped_key_kcv = session.encrypt( :DES3_ECB, unwrapped_key, "\0"*8)
    assert_equal secret_key_kcv, unwrapped_key_kcv, 'Key check values of original and wrapped/unwrapped key should be equal'
  end

  def test_wrap_private_key
    wrapped_key_value = session.wrap_key({:DES3_CBC_PAD=>"\0"*8}, secret_key, rsa_priv_key)
    assert wrapped_key_value.length>100, 'RSA private key should have bigger size wrapped'
  end

  def test_generate_secret_key
    key = session.generate_key(:DES2_KEY_GEN,
      {:ENCRYPT=>true, :WRAP=>true, :DECRYPT=>true, :UNWRAP=>true, :TOKEN=>false, :LOCAL=>true})
    assert_equal true, key[:LOCAL], 'Keys created on the token should be marked as local'
  end

  def test_generate_key_pair
    pub_key, priv_key = session.generate_key_pair(:RSA_PKCS_KEY_PAIR_GEN,
      {:ENCRYPT=>true, :VERIFY=>true, :WRAP=>true, :MODULUS_BITS=>768, :PUBLIC_EXPONENT=>[3].pack("N"), :TOKEN=>false},
      {:PRIVATE=>true,:SUBJECT=>'test', :ID=>[123].pack("n"),
       :SENSITIVE=>true, :DECRYPT=>true, :SIGN=>true, :UNWRAP=>true, :TOKEN=>false, :LOCAL=>true})
    
    assert_equal true, priv_key[:LOCAL], 'Private keys created on the token should be marked as local'
    assert_equal priv_key[:CLASS], CKO_PRIVATE_KEY
    assert_equal pub_key[:CLASS], CKO_PUBLIC_KEY
    assert_equal true, priv_key[:SENSITIVE], 'Private key should be sensitive'
  end

end