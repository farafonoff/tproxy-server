package session

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"hash"
)

type TokenClass byte

const (
	TokenExternal TokenClass = iota
	TokenBootstrap
	TokenSession
)

var (
	tokenContext       = []byte("tproxy-server-token-v2\x00")
	tokenContextV1     = []byte("tproxy-server-token-v1\x00")
	tokenFilterContext = []byte("tproxy-server-token-filter-v2\x00")
)

// A token's nonce is 12 random bytes and a 4-byte filter tag: the first bytes of
// AES under a key derived from the token key, over the random bytes. The tag
// rejects all but 2^-32 of arbitrary candidates with one block cipher call, so
// scanning request metadata computes the HMACs almost only for real tokens. It
// must stay keyed: a public tag would let clients pass it at every offset.
const (
	tokenRandomBytes = 12
	tokenNonceBytes  = 16
)

func newTokenFilter(tokenKey [sha256.Size]byte) cipher.Block {
	mac := hmac.New(sha256.New, tokenKey[:])
	_, _ = mac.Write(tokenFilterContext)
	block, err := aes.NewCipher(mac.Sum(nil)[:16])
	if err != nil {
		panic(err)
	}
	return block
}

// TokenClassifier reuses one keyed HMAC state, so a candidate costs a block
// cipher call and no allocation. Scanning request metadata classifies one
// candidate per base64 offset, and anyone can send that metadata. Not safe for
// concurrent use.
type TokenClassifier struct {
	filter cipher.Block
	mac    hash.Hash
	kind   [1]byte
	block  [aes.BlockSize]byte
	sum    [sha256.Size]byte
}

func (m *Manager) NewTokenClassifier() *TokenClassifier {
	return &TokenClassifier{
		filter: m.tokenFilter,
		mac:    hmac.New(sha256.New, m.tokenKey[:]),
	}
}

// The result aliases the classifier and is valid until its next use.
func (c *TokenClassifier) filterTag(nonce []byte) []byte {
	c.block = [aes.BlockSize]byte{}
	copy(c.block[:], nonce[:tokenRandomBytes])
	c.filter.Encrypt(c.block[:], c.block[:])
	return c.block[:tokenNonceBytes-tokenRandomBytes]
}

// The result aliases the classifier and is valid until its next use.
func (c *TokenClassifier) tokenMAC(context []byte, kind TokenClass, nonce []byte) []byte {
	c.mac.Reset()
	c.kind[0] = byte(kind)
	_, _ = c.mac.Write(context)
	_, _ = c.mac.Write(c.kind[:])
	_, _ = c.mac.Write(nonce)
	return c.mac.Sum(c.sum[:0])[:16]
}

// Classify takes a decoded candidate, as ClassifyToken after base64 decoding.
func (c *TokenClassifier) Classify(decoded []byte) TokenClass {
	if len(decoded) != 32 ||
		subtle.ConstantTimeCompare(decoded[tokenRandomBytes:tokenNonceBytes], c.filterTag(decoded)) != 1 {
		return TokenExternal
	}
	bootstrap := subtle.ConstantTimeCompare(decoded[tokenNonceBytes:], c.tokenMAC(tokenContext, TokenBootstrap, decoded[:tokenNonceBytes]))
	session := subtle.ConstantTimeCompare(decoded[tokenNonceBytes:], c.tokenMAC(tokenContext, TokenSession, decoded[:tokenNonceBytes]))
	if bootstrap == 1 {
		return TokenBootstrap
	}
	if session == 1 {
		return TokenSession
	}
	return TokenExternal
}

// SignedV1 recognizes tokens issued before the filter tag: a 16-byte random
// nonce under the v1 MAC context. The upgrade restart discards their sessions,
// but pages still holding them must fail locally and reconnect, not send their
// carrier requests to the website. It costs two HMACs, so callers check only
// the fields where the bridge page sends credentials.
func (c *TokenClassifier) SignedV1(decoded []byte) bool {
	if len(decoded) != 32 {
		return false
	}
	bootstrap := subtle.ConstantTimeCompare(decoded[16:], c.tokenMAC(tokenContextV1, TokenBootstrap, decoded[:16]))
	session := subtle.ConstantTimeCompare(decoded[16:], c.tokenMAC(tokenContextV1, TokenSession, decoded[:16]))
	return bootstrap|session == 1
}

func (m *Manager) newToken(kind TokenClass) (string, [sha256.Size]byte, error) {
	var input [32]byte
	if _, err := rand.Read(input[:tokenRandomBytes]); err != nil {
		return "", [sha256.Size]byte{}, fmt.Errorf("random token: %w", err)
	}
	classifier := m.NewTokenClassifier()
	copy(input[tokenRandomBytes:tokenNonceBytes], classifier.filterTag(input[:]))
	copy(input[tokenNonceBytes:], classifier.tokenMAC(tokenContext, kind, input[:tokenNonceBytes]))
	return base64.RawURLEncoding.EncodeToString(input[:]), sha256.Sum256(input[:]), nil
}

// Classification authenticates provenance, not liveness or permission to use
// a carrier. Both MACs are checked even on expired and misplaced credentials.
// Lenient base64 decoding here also contains noncanonical spellings locally;
// tokenHash still requires canonical encoding when authorizing an operation.
func (m *Manager) ClassifyToken(token string) TokenClass {
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return TokenExternal
	}
	return m.NewTokenClassifier().Classify(decoded)
}
