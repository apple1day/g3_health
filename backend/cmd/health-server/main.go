package main
import (
 "context"
 "errors"
 "flag"
 "fmt"
 "log"
 "net/http"
 "os"
 "os/signal"
 "strconv"
 "syscall"
 "time"
 "github.com/apple1day/g3_health/backend/internal/api"
 "github.com/apple1day/g3_health/backend/internal/config"
 "github.com/apple1day/g3_health/backend/internal/store"
)
func main(){if err:=run();err!=nil{fmt.Fprintln(os.Stderr,err);os.Exit(1)}}
func run()error{
 action:="serve";args:=os.Args[1:];if len(args)>0&&len(args[0])>0&&args[0][0]!='-'{action=args[0];args=args[1:]}
 flags:=flag.NewFlagSet("health-server",flag.ContinueOnError)
 path:=flags.String("config","config.local.yaml","private YAML configuration")
 legacy:=flags.String("legacy-env","../server/.env","legacy token file; read only during init-config")
 create:=flags.Bool("create-database",false,"create database IF NOT EXISTS during migrate")
 role:=flags.String("role","upload","token role: upload/read/admin")
 if err:=flags.Parse(args);err!=nil{return err}
 if flags.NArg()!=0{return errors.New("unexpected arguments")}
 if action=="init-config"{if err:=config.Init(*path,*legacy);err!=nil{return err};fmt.Println("本机配置已生成；保留旧上传/读取令牌；未输出密码或令牌。");return nil}
 c,err:=config.Load(*path);if err!=nil{return err}
 switch action {
 case "token":
  token:="";switch *role{case "upload":token=c.Security.UploadToken;case "read":token=c.Security.ReadToken;case "admin":token=c.Security.AdminToken;default:return errors.New("role 只能是 upload/read/admin")}
  // Explicit local-only command. Normal startup/API never prints/exposes tokens.
  fmt.Print(token);return nil
 case "migrate":
  ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second);defer cancel()
  if err=store.Migrate(ctx,c,*create);err!=nil{return err};fmt.Println("MySQL 数据表初始化完成（未删除已有数据）。");return nil
 case "serve":
 default:return errors.New("action 必须为 init-config / migrate / token / serve")
 }
 repo,err:=store.New(c);if err!=nil{return err};defer repo.DB.Close()
 if _,err=repo.Overview(context.Background());err!=nil{return errors.New("数据库表尚未初始化或不可读，请运行 bash setup-backend.sh")}
 server:=&http.Server{Addr:c.Server.Host+":"+strconv.Itoa(c.Server.Port),Handler:api.New(c,repo),ReadHeaderTimeout:5*time.Second,ReadTimeout:20*time.Second,WriteTimeout:20*time.Second,IdleTimeout:60*time.Second,MaxHeaderBytes:16*1024}
 ctx,stop:=signal.NotifyContext(context.Background(),os.Interrupt,syscall.SIGTERM);defer stop()
 done:=make(chan error,1);go func(){done<-server.ListenAndServe()}()
 log.Printf("Health Glance Gin 服务端口 %d；管理页 /admin/；令牌和健康内容不写日志。",c.Server.Port)
 log.Print("HTTP 仅用于可信局域网测试；公网必须使用 HTTPS，并改用受限数据库账号。")
 select{case err=<-done:if errors.Is(err,http.ErrServerClosed){return nil};return errors.New("服务启动失败：请检查端口是否被旧服务占用")
 case <-ctx.Done():shutdown,cancel:=context.WithTimeout(context.Background(),10*time.Second);defer cancel();return server.Shutdown(shutdown)}
}
