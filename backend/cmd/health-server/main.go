package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"github.com/apple1day/g3_health/backend/internal/api"
	"github.com/apple1day/g3_health/backend/internal/config"
	"github.com/apple1day/g3_health/backend/internal/store"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	action := "serve"
	args := os.Args[1:]
	if len(args) > 0 && len(args[0]) > 0 && args[0][0] != '-' {
		action = args[0]
		args = args[1:]
	}
	flags := flag.NewFlagSet("health-server", flag.ContinueOnError)
	path := flags.String("config", "config.local.yaml", "private YAML configuration")
	legacy := flags.String("legacy-env", "../server/.env", "legacy CORS settings; read only during init-config")
	create := flags.Bool("create-database", false, "create database IF NOT EXISTS during migrate")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected arguments")
	}
	if action == "init-config" {
		if err := config.Init(*path, *legacy); err != nil {
			return err
		}
		fmt.Println("本机数据库配置已生成；免 Token 模式，仅用于可信局域网。")
		return nil
	}
	c, err := config.Load(*path)
	if err != nil {
		return err
	}
	switch action {
	case "migrate":
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err = store.Migrate(ctx, c, *create); err != nil {
			return err
		}
		fmt.Println("MySQL 数据表初始化完成（未删除已有数据）。")
		return nil
	case "serve":
	default:
		return errors.New("action 必须为 init-config / migrate / serve；当前版本无需 Token")
	}
	repo, err := store.New(c)
	if err != nil {
		return err
	}
	defer repo.DB.Close()
	if _, err = repo.Overview(context.Background()); err != nil {
		return errors.New("数据库表尚未初始化或不可读，请运行 bash setup-backend.sh")
	}
	server := &http.Server{Addr: c.Server.Host + ":" + strconv.Itoa(c.Server.Port), Handler: api.New(c, repo), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	log.Printf("Health Glance Gin 服务端口 %d；管理页 /admin/；免 Token 模式；健康内容不写日志。", c.Server.Port)
	log.Print("警告：无身份认证，能连接服务的人均可读取、上传、删除全部健康历史。仅限可信局域网，禁止公网映射；HTTPS 不能替代登录认证。")
	select {
	case err = <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return errors.New("服务启动失败：请检查端口是否被旧服务占用")
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
}
