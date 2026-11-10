export async function request(path, signal) {
 if (!path.startsWith('/api/admin/')) throw new Error('不允许的接口路径');
 let response;
 try {
  response = await fetch(path, { signal, cache: 'no-store', credentials: 'omit', redirect: 'error' });
 } catch (error) {
  if (error.name === 'AbortError') throw error;
  throw new Error('无法连接后台，请确认 Gin 服务已启动。');
 }
 if (!response.ok) {
  const error = new Error(({ 401: '服务仍要求登录，请更新并重启免 Token 版 Gin 后端。', 403: '浏览器访问被限制，请从服务自身的 /admin/ 打开。', 400: '日期范围不正确，趋势最多查询 366 天。', 404: '未找到这条记录。', 429: '验证失败次数过多，请稍后重试。', 503: '数据库暂时不可用，请检查 MySQL。' })[response.status] || `请求失败（${response.status}）`);
  error.status = response.status; throw error;
 }
 return response.json();
}
