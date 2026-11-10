package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitKeepsTokensAndPermissions(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "old.env")
	path := filepath.Join(dir, "config.local.yaml")
	u := strings.Repeat("u", 43)
	r := strings.Repeat("r", 43)
	os.WriteFile(old, []byte("UPLOAD_TOKEN="+u+"\nREAD_TOKEN="+r+"\nALLOWED_ORIGINS=*\n"), 0600)
	t.Setenv("MYSQL_PASSWORD", "ci-only-password")
	if e := Init(path, old); e != nil {
		t.Fatal(e)
	}
	c, e := Load(path)
	if e != nil {
		t.Fatal(e)
	}
	if c.Security.UploadToken != u || c.Security.ReadToken != r || c.MySQL.Password != "ci-only-password" {
		t.Fatal("legacy settings lost")
	}
	if c.Security.AdminToken == u || len(c.Security.AdminToken) < 32 {
		t.Fatal("bad admin token")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("unsafe permissions")
	}
	if Init(path, old) == nil {
		t.Fatal("overwrites existing config")
	}
}
func TestIdentifierAndTokenValidation(t *testing.T) {
	c := Default()
	c.Security = Security{strings.Repeat("u", 43), strings.Repeat("r", 43), strings.Repeat("a", 43)}
	if e := c.Validate(); e != nil {
		t.Fatal(e)
	}
	c.MySQL.Prefix = "x`;DROP TABLE x;"
	if c.Validate() == nil {
		t.Fatal("SQL identifier accepted")
	}
	c = Default()
	c.Security = Security{strings.Repeat("u", 43), strings.Repeat("u", 43), strings.Repeat("a", 43)}
	if c.Validate() == nil {
		t.Fatal("shared role tokens accepted")
	}
}
func TestDSNPasswordIsNotConcatenated(t *testing.T) {
	c := Default()
	c.MySQL.Password = "a@b:/?#secret"
	m, e := c.DriverConfig(false)
	if e != nil {
		t.Fatal(e)
	}
	if m.Passwd != c.MySQL.Password || !m.ParseTime || m.Loc.String() != "Local" {
		t.Fatal("incorrect driver configuration")
	}
	c.MySQL.Config = "charset=utf8mb4&multiStatements=true"
	if _, e = c.DriverConfig(false); e == nil {
		t.Fatal("unsafe config accepted")
	}
}
func TestLegacyDoesNotExecuteShell(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "old.env")
	os.WriteFile(p, []byte("UPLOAD_TOKEN=$(touch should-not-exist)\n"), 0600)
	if e := Init(filepath.Join(d, "private.yaml"), p); e == nil {
		t.Fatal("invalid token accepted")
	}
}
