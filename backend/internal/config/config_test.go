package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitWithoutTokensKeepsDatabaseAndPermissions(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "old.env")
	path := filepath.Join(dir, "config.local.yaml")
	if e := os.WriteFile(old, []byte("UPLOAD_TOKEN=obsolete\nREAD_TOKEN=obsolete\nALLOWED_ORIGINS=http://localhost:5173\n"), 0600); e != nil {
		t.Fatal(e)
	}
	t.Setenv("MYSQL_PASSWORD", "ci-only-password")
	t.Setenv("UPLOAD_TOKEN", "ignored")
	if e := Init(path, old); e != nil {
		t.Fatal(e)
	}
	c, e := Load(path)
	if e != nil {
		t.Fatal(e)
	}
	if c.MySQL.Password != "ci-only-password" || c.Security != (Security{}) {
		t.Fatal("bad configuration")
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "security:") || strings.Contains(string(raw), "token:") {
		t.Fatal("new config contains token fields")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("unsafe permissions")
	}
	if Init(path, old) == nil {
		t.Fatal("overwrote existing config")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(raw) {
		t.Fatal("configuration changed")
	}
}
func TestOldYAMLWorksWithoutTokenValidationOrRewrite(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.local.yaml")
	raw := []byte("mysql:\n  password: keep-local-password\nsecurity:\n  upload-token: x\n  read-token: x\n  admin-token: ''\n")
	if e := os.WriteFile(p, raw, 0600); e != nil {
		t.Fatal(e)
	}
	c, e := Load(p)
	if e != nil {
		t.Fatal(e)
	}
	if c.MySQL.Password != "keep-local-password" || c.Security != (Security{}) {
		t.Fatal("old fields were enforced or password lost")
	}
	after, _ := os.ReadFile(p)
	if string(after) != string(raw) {
		t.Fatal("load rewrote old file")
	}
}
func TestIdentifierValidationStillRequired(t *testing.T) {
	c := Default()
	if e := c.Validate(); e != nil {
		t.Fatal(e)
	}
	c.MySQL.Prefix = "x`;DROP TABLE x;"
	if c.Validate() == nil {
		t.Fatal("unsafe identifier accepted")
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
		t.Fatal("incorrect driver config")
	}
	c.MySQL.Config = "charset=utf8mb4&multiStatements=true"
	if _, e = c.DriverConfig(false); e == nil {
		t.Fatal("unsafe config accepted")
	}
}
func TestLegacyTokensNeverExecutedOrMigrated(t *testing.T) {
	d := t.TempDir()
	marker := filepath.Join(d, "unexpected")
	p := filepath.Join(d, "old.env")
	if e := os.WriteFile(p, []byte("UPLOAD_TOKEN=$(touch "+marker+")\n"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := Init(filepath.Join(d, "config.yaml"), p); e != nil {
		t.Fatal(e)
	}
	if _, e := os.Stat(marker); !os.IsNotExist(e) {
		t.Fatal("legacy input was executed")
	}
}
