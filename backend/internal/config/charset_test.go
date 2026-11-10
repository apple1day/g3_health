package config

import("strings";"testing")

func TestCharsetIsDriverOptionNotSystemVariable(t *testing.T) {
 c:=Default();m,e:=c.DriverConfig(false);if e!=nil{t.Fatal(e)}
 if _,ok:=m.Params["charset"];ok{t.Fatal("charset must use the driver's SET NAMES option")}
 if !strings.Contains(m.FormatDSN(),"charset=utf8mb4"){t.Fatal("missing utf8mb4 driver charset")}
}
