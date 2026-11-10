package config

import (
	"bufio"
	"errors"
	"fmt"
	"github.com/go-sql-driver/mysql"
	"gopkg.in/yaml.v3"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	MySQL    MySQL    `yaml:"mysql"`
	Server   Server   `yaml:"server"`
	Security Security `yaml:"security,omitempty"` // Deprecated: accept old YAML, never authenticate.
}
type MySQL struct {
	Prefix   string `yaml:"prefix"`
	Port     string `yaml:"port"`
	Config   string `yaml:"config"`
	DBName   string `yaml:"db-name"`
	Username string `yaml:"username"`
	Password string `yaml:"password"`
	Path     string `yaml:"path"`
}
type Server struct {
	Host           string   `yaml:"host"`
	Port           int      `yaml:"port"`
	AdminDist      string   `yaml:"admin-dist"`
	AllowedOrigins []string `yaml:"allowed-origins"`
}
type Security struct {
	UploadToken string `yaml:"upload-token,omitempty"`
	ReadToken   string `yaml:"read-token,omitempty"`
	AdminToken  string `yaml:"admin-token,omitempty"`
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_]+$`)

func Default() Config {
	return Config{
		MySQL:  MySQL{Port: "3306", Config: "charset=utf8mb4&parseTime=True&loc=Local", DBName: "g3_health", Username: "root", Path: "127.0.0.1"},
		Server: Server{Host: "0.0.0.0", Port: 8787, AdminDist: "../web-admin/dist", AllowedOrigins: []string{"http://localhost:5173", "http://127.0.0.1:5173"}},
	}
}
func Load(path string) (Config, error) {
	c := Default()
	f, err := os.Open(path)
	if err != nil {
		return c, fmt.Errorf("无法读取配置文件，请先运行 bash setup-backend.sh")
	}
	defer f.Close()
	dec := yaml.NewDecoder(io.LimitReader(f, 65537))
	dec.KnownFields(true)
	if dec.Decode(&c) != nil {
		return c, errors.New("配置 YAML 格式不正确，请检查字段名和缩进")
	}
	var extra any
	if dec.Decode(&extra) != io.EOF {
		return c, errors.New("配置只能包含一个 YAML 文档")
	}
	c.Security = Security{} // Ignore deprecated keys without changing the on-disk file.
	overrides(&c)
	if err = c.Validate(); err != nil {
		return c, err
	}
	if !filepath.IsAbs(c.Server.AdminDist) {
		c.Server.AdminDist = filepath.Join(filepath.Dir(path), c.Server.AdminDist)
	}
	return c, nil
}
func overrides(c *Config) {
	for key, p := range map[string]*string{"MYSQL_PASSWORD": &c.MySQL.Password, "MYSQL_HOST": &c.MySQL.Path, "MYSQL_PORT": &c.MySQL.Port, "MYSQL_USER": &c.MySQL.Username, "MYSQL_DATABASE": &c.MySQL.DBName} {
		if v, ok := os.LookupEnv(key); ok {
			*p = v
		}
	}
	if v := os.Getenv("PORT"); v != "" {
		n, e := strconv.Atoi(v)
		if e != nil {
			c.Server.Port = -1
		} else {
			c.Server.Port = n
		}
	}
}
func (c Config) Validate() error {
	if !identifier.MatchString(c.MySQL.DBName) || len(c.MySQL.DBName) > 64 || len(c.MySQL.Prefix) > 32 || (c.MySQL.Prefix != "" && !identifier.MatchString(c.MySQL.Prefix)) {
		return errors.New("数据库名/表前缀只能包含字母、数字和下划线")
	}
	if c.MySQL.Path == "" || c.MySQL.Username == "" {
		return errors.New("MySQL 地址和用户名不能为空")
	}
	p, err := strconv.Atoi(c.MySQL.Port)
	if err != nil || p < 1 || p > 65535 {
		return errors.New("MySQL 端口不正确")
	}
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		return errors.New("服务端口不正确")
	}
	for _, origin := range c.Server.AllowedOrigins {
		if origin == "*" || origin == "null" {
			continue
		}
		u, e := url.Parse(origin)
		if e != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" {
			return errors.New("CORS 白名单需为 origin，不含路径、密码或参数")
		}
	}
	_, err = c.DriverConfig(false)
	return err
}
func (c Config) DriverConfig(withoutDatabase bool) (*mysql.Config, error) {
	params, err := url.ParseQuery(c.MySQL.Config)
	if err != nil {
		return nil, errors.New("MySQL config 参数不正确")
	}
	m := mysql.NewConfig()
	m.User = c.MySQL.Username
	m.Passwd = c.MySQL.Password
	m.Net = "tcp"
	m.Addr = net.JoinHostPort(c.MySQL.Path, c.MySQL.Port)
	m.DBName = c.MySQL.DBName
	if withoutDatabase {
		m.DBName = ""
	}
	m.ParseTime = true
	m.Loc = time.Local
	m.Timeout = 5 * time.Second
	m.ReadTimeout = 15 * time.Second
	m.WriteTimeout = 15 * time.Second
	// Charset is a driver option (SET NAMES), not a MySQL system variable.
	if err = m.Apply(mysql.Charset("utf8mb4", "")); err != nil {
		return nil, errors.New("无法配置 MySQL utf8mb4 字符集")
	}
	for key, values := range params {
		if len(values) != 1 {
			return nil, errors.New("MySQL config 不允许重复参数")
		}
		v := values[0]
		switch key {
		case "charset":
			if v != "utf8mb4" {
				return nil, errors.New("数据库编码必须为 utf8mb4")
			}
		case "parseTime":
			parsed, e := strconv.ParseBool(v)
			if e != nil || !parsed {
				return nil, errors.New("parseTime 必须为 True")
			}
		case "loc":
			m.Loc, err = time.LoadLocation(v)
			if err != nil {
				return nil, errors.New("MySQL loc 时区不正确")
			}
		case "tls":
			if v != "true" && v != "false" {
				return nil, errors.New("tls 仅允许 true 或 false")
			}
			m.TLSConfig = v
		default:
			return nil, errors.New("不支持的 MySQL config 参数，仅允许 charset/parseTime/loc/tls")
		}
	}
	return m, nil
}

// Init creates database configuration once. Old CORS settings can be migrated;
// legacy tokens are neither generated nor required. Existing YAML is never replaced.
func Init(path, legacy string) error {
	if _, e := os.Stat(path); e == nil {
		return errors.New("本机配置已存在，未覆盖；需要修改时请编辑 backend/config.local.yaml")
	}
	c := Default()
	old, err := readLegacy(legacy)
	if err != nil {
		return err
	}
	if origin := old["ALLOWED_ORIGINS"]; origin != "" {
		c.Server.AllowedOrigins = nil
		for _, o := range strings.Split(origin, ",") {
			c.Server.AllowedOrigins = append(c.Server.AllowedOrigins, strings.TrimSpace(o))
		}
	}
	overrides(&c)
	if err = c.Validate(); err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return errors.New("无法创建配置目录")
	}
	raw, err := yaml.Marshal(c)
	if err != nil {
		return errors.New("无法编码配置")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("无法新建配置；已有文件不会被覆盖")
	}
	defer f.Close()
	if _, err = f.Write(append([]byte("# 本机私有配置：包含数据库密码，禁止提交或截图分享。\n"), raw...)); err != nil {
		return errors.New("写入本机配置失败")
	}
	return f.Sync()
}
func readLegacy(path string) (map[string]string, error) {
	result := map[string]string{}
	if path == "" {
		return result, nil
	}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return result, nil
	}
	if err != nil {
		return nil, errors.New("无法读取旧 server/.env")
	}
	defer f.Close()
	scanner := bufio.NewScanner(io.LimitReader(f, 65537))
	for scanner.Scan() {
		s := strings.TrimSpace(scanner.Text())
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		k, v, ok := strings.Cut(s, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(strings.TrimPrefix(k, "export "))
		v = strings.TrimSpace(v)
		if len(v) >= 2 && ((v[0] == '\'' && v[len(v)-1] == '\'') || (v[0] == '"' && v[len(v)-1] == '"')) {
			v = v[1 : len(v)-1]
		}
		switch k {
		case "ALLOWED_ORIGINS":
			if _, exists := result[k]; exists {
				return nil, errors.New("旧 .env 存在重复配置，未迁移")
			}
			result[k] = v
		}
	}
	if scanner.Err() != nil {
		return nil, errors.New("旧 .env 文件格式错误")
	}
	return result, nil
}
