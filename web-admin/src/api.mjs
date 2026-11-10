export async function request(path, token, signal) {
 if (!path.startsWith('/api/admin/')) throw new Error('不允许的接口路径');
 let response;
 try {
  response = await fetch(path, { headers: { Authorization: `Bearer ${token}` }, signal, cache: 'no-store', credentials: 'omit', redirect: 'error' });
 } catch (error) {
  if (error.name === 'AbortError') throw error;
  throw new Error('无法连接后台，请确认 Gin 服务已启动。');
 }
 if (!response.ok) {
  const error = new Error(({ 401: '管理令牌不正确，请使用 ADMIN_TOKEN，不是上传令牌。', 400: '日期范围不正确，趋势最多查询 366 天。', 404: '未找到这条记录。', 429: '验证失败次数过多，请稍后重试。', 503: '数据库暂时不可用，请检查 MySQL。' })[response.status] || `请求失败（${response.status}）`);
  error.status = response.status; throw error;
 }
 return response.json();
}
