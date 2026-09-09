package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// 测试统一指向仓库中的真实配置目录，避免测试与生产读到不同的结构。
const testConfigDir = "../../configs"

func setSecrets(t *testing.T) {
	t.Helper()
	t.Setenv("STEAMLINK_STEAM_API_KEY", "TESTKEY")
	t.Setenv("PLAYPILOT_MYSQL_PASSWORD", "testpass")
	t.Setenv("STEAMLINK_AUTH_STATE_SECRET", "test-state-secret")
}

func TestLoad_MergesBaseAndEnvFiles(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	setSecrets(t)

	cfg, err := Load(testConfigDir)
	require.NoError(t, err)

	// 来自基础配置。地址带回环前缀不是笔误：本服务只信任 Gateway 注入的
	// X-User-Id，绑到全部网卡等于把鉴权敞开，见 configs/config.yaml 的说明。
	require.Equal(t, "127.0.0.1:9994", cfg.HTTP.Addr)
	require.Equal(t, 3306, cfg.MySQL.Port)
	require.Equal(t, 5, cfg.Steam.RatePerSec)
	// 被 local 覆盖
	require.Equal(t, "debug", cfg.Log.Level)
	require.Equal(t, "text", cfg.Log.Format)
}

// 环境变量优先级最高，覆盖两个 YAML。
func TestLoad_EnvOverridesYAML(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	setSecrets(t)
	t.Setenv("STEAMLINK_HTTP_ADDR", ":9999")
	t.Setenv("STEAMLINK_LOG_LEVEL", "warn")

	cfg, err := Load(testConfigDir)
	require.NoError(t, err)
	require.Equal(t, ":9999", cfg.HTTP.Addr)
	require.Equal(t, "warn", cfg.Log.Level)
}

// 这是 viper 最经典的坑：AutomaticEnv 只在 Get 时生效，
// Unmarshal 走 AllKeys，若某个 key 不在任何 YAML 中就读不到环境变量。
// 三个敏感项在 YAML 中留空正是为了让它们出现在 AllKeys 里，
// 同时实现里还要显式 BindEnv 作为双保险。此用例守住这个行为。
func TestLoad_SecretsComeFromEnvNotYAML(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	setSecrets(t)

	cfg, err := Load(testConfigDir)
	require.NoError(t, err)
	require.Equal(t, "TESTKEY", cfg.Steam.APIKey)
	require.Equal(t, "test-state-secret", cfg.Auth.StateSecret)
	require.Equal(t, "testpass", cfg.MySQL.Password)
}

// 缺失敏感项必须启动即失败，而不是等到第一次调用 Steam 才暴露。
func TestLoad_MissingSecretFails(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	t.Setenv("STEAMLINK_STEAM_API_KEY", "")
	t.Setenv("PLAYPILOT_MYSQL_PASSWORD", "testpass")
	t.Setenv("STEAMLINK_AUTH_STATE_SECRET", "test-state-secret")

	_, err := Load(testConfigDir)
	require.ErrorIs(t, err, ErrMissingSecret)
	require.Contains(t, err.Error(), "STEAMLINK_STEAM_API_KEY")
}

// 生产环境必须显式提供 base_url 且为 https ——
// 沿用 localhost 会让 OpenID 回调静默失败，极难排查。
func TestLoad_ProdRequiresHTTPSBaseURL(t *testing.T) {
	t.Setenv("APP_ENV", EnvProd)
	setSecrets(t)
	t.Setenv("STEAMLINK_HTTP_BASE_URL", "")

	_, err := Load(testConfigDir)
	require.Error(t, err, "prod 下 base_url 为空必须失败")

	t.Setenv("STEAMLINK_HTTP_BASE_URL", "http://example.com")
	_, err = Load(testConfigDir)
	require.Error(t, err, "prod 下必须是 https")

	t.Setenv("STEAMLINK_HTTP_BASE_URL", "https://example.com")
	cfg, err := Load(testConfigDir)
	require.NoError(t, err)
	require.Equal(t, "https://example.com", cfg.HTTP.BaseURL)
}

// test 环境是「本地跑服务、连阿里云实例」，地址全部由 test.env 注入，
// 因此 YAML 里不该出现真实地址，base_url 仍是本地。
func TestLoad_TestEnvKeepsLocalBaseURL(t *testing.T) {
	t.Setenv("APP_ENV", EnvTest)
	setSecrets(t)

	cfg, err := Load(testConfigDir)
	require.NoError(t, err)
	require.Equal(t, EnvTest, cfg.App.Env)
	require.Equal(t, "http://localhost:9980", cfg.HTTP.BaseURL)
}

// APP_ENV 写错时必须启动即失败。若放任不管，viper 只会静默跳过
// 不存在的 config.{env}.yaml，服务带着一份基础配置照常启动 ——
// 结果就是拿本地地址连生产，或反过来。
func TestLoad_UnknownEnvFails(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	setSecrets(t)

	_, err := Load(testConfigDir)
	require.ErrorIs(t, err, ErrUnknownEnv)
	require.Contains(t, err.Error(), "local")
}

// duration 字符串必须能被解析成 time.Duration。
func TestLoad_ParsesDurations(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	setSecrets(t)

	cfg, err := Load(testConfigDir)
	require.NoError(t, err)
	require.Equal(t, 2*time.Second, cfg.Worker.PollInterval)
}

// DSN 必须强制带上 parseTime 与 UTC，不允许配置文件改动它们。
func TestMySQLDSN_ForcesParseTimeAndUTC(t *testing.T) {
	c := MySQLConfig{
		Host: "db.internal", Port: 3306,
		User: "app", Password: "pw", Database: "steamlink",
	}
	dsn := c.DSN()

	require.Contains(t, dsn, "app:pw@tcp(db.internal:3306)/steamlink")
	require.Contains(t, dsn, "parseTime=true")
	require.Contains(t, dsn, "loc=UTC")
	require.Contains(t, dsn, "charset=utf8mb4")
}

// ---------- 共享配置目录/{env}.env ----------

// clearEnv 清掉指定的环境变量并在用例结束时还原。
//
// 必需：真实环境变量的优先级高于 .env，而调用方可能带着
// STEAMLINK_* 前缀跑测试（scripts/dev/test.sh 就是这么做的）。
// 不清掉，下面几个用例验证的就不是文件里的值了。
func clearEnv(t *testing.T, keys ...string) {
	t.Helper()
	for _, k := range keys {
		if old, ok := os.LookupEnv(k); ok {
			t.Cleanup(func() { _ = os.Setenv(k, old) })
		}
		require.NoError(t, os.Unsetenv(k))
	}
}

func clearSteamlinkEnv(t *testing.T) {
	t.Helper()
	clearEnv(t,
		"STEAMLINK_STEAM_API_KEY",
		"PLAYPILOT_MYSQL_HOST", "PLAYPILOT_MYSQL_PORT", "PLAYPILOT_MYSQL_USERNAME",
		"PLAYPILOT_MYSQL_PASSWORD", "STEAMLINK_MYSQL_DATABASE",
		"PLAYPILOT_REDIS_HOST", "PLAYPILOT_REDIS_PORT", "PLAYPILOT_REDIS_PASSWORD",
		"STEAMLINK_REDIS_DATABASE",
		"STEAMLINK_AUTH_STATE_SECRET", "STEAMLINK_HTTP_BASE_URL",
	)
}

// 用临时目录构造共享 env，避免依赖工作空间里不进版本控制的真实文件。
func envFileDir(t *testing.T, envName, content string) string {
	t.Helper()
	clearSteamlinkEnv(t)
	dir := t.TempDir()

	require.NoError(t, os.WriteFile(
		filepath.Join(dir, envName+".env"), []byte(content), 0o600))
	return dir
}

// 地址与密钥都从共享 {env}.env 读入，仓库里不必有任何真实值。
func TestLoad_ReadsEnvFile(t *testing.T) {
	t.Setenv("APP_ENV", EnvTest)
	dir := envFileDir(t, EnvTest, `
# 阿里云实例（公网）
PLAYPILOT_MYSQL_HOST=rm-example.mysql.rds.aliyuncs.com
PLAYPILOT_MYSQL_PORT=3307
PLAYPILOT_MYSQL_PASSWORD="p@ss word#1"
export PLAYPILOT_REDIS_HOST=r-example.redis.rds.aliyuncs.com
PLAYPILOT_REDIS_PORT=6380
STEAMLINK_STEAM_API_KEY=KEYFROMFILE
STEAMLINK_AUTH_STATE_SECRET=secret-from-file
`)

	cfg, err := LoadWithEnvDir(testConfigDir, dir)
	require.NoError(t, err)

	require.Equal(t, "rm-example.mysql.rds.aliyuncs.com", cfg.MySQL.Host)
	require.Equal(t, 3307, cfg.MySQL.Port)
	require.Equal(t, "p@ss word#1", cfg.MySQL.Password, "引号内的空格与 # 必须原样保留")
	require.Equal(t, "r-example.redis.rds.aliyuncs.com:6380", cfg.Redis.Address())
	require.Equal(t, "KEYFROMFILE", cfg.Steam.APIKey)
}

// 真实环境变量优先于 .env —— 部署时用容器变量覆盖文件里的任意一项，
// 不需要先把文件删掉。
func TestLoad_RealEnvBeatsEnvFile(t *testing.T) {
	t.Setenv("APP_ENV", EnvTest)
	dir := envFileDir(t, EnvTest, `
PLAYPILOT_MYSQL_HOST=from-file
PLAYPILOT_MYSQL_PASSWORD=pw
STEAMLINK_STEAM_API_KEY=k
STEAMLINK_AUTH_STATE_SECRET=s
`)
	// 在 envFileDir 清空环境之后再设，模拟部署时的容器变量
	t.Setenv("PLAYPILOT_MYSQL_HOST", "from-real-env")

	cfg, err := LoadWithEnvDir(testConfigDir, dir)
	require.NoError(t, err)
	require.Equal(t, "from-real-env", cfg.MySQL.Host)
}

// .env 缺失不是错误：生产可以只注入容器环境变量，不落盘密钥文件。
func TestLoad_MissingEnvFileIsFine(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	setSecrets(t)

	dir := t.TempDir()
	_, err := LoadWithEnvDir(testConfigDir, dir)
	require.NoError(t, err)
}

// 格式错误要指出行号，而不是静默跳过 —— 少一个等号就少一项配置，
// 排查起来比启动失败痛苦得多。
func TestLoad_MalformedEnvFileFails(t *testing.T) {
	t.Setenv("APP_ENV", EnvLocal)
	dir := envFileDir(t, EnvLocal, "PLAYPILOT_MYSQL_PASSWORD=pw\nJUST_A_KEY\n")

	_, err := LoadWithEnvDir(testConfigDir, dir)
	require.Error(t, err)
	require.Contains(t, err.Error(), "第 2 行")
}
