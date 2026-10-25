use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::{
    config,
    crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

const LITE_T1_KEY: &str = "5e4ef500e9597fe004bd09a46d8add98";
const LITE_T1_IV: &str = "04bd09a46d8add98";
const LITE_T2_KEY: &str = "fd14b35e3f81af3817a20ae7adae7020";
const LITE_T2_IV: &str = "17a20ae7adae7020";
const T2_FIXED_HASH: &str = "0f607264fc6318a92b9e13c65db7cd3c";
const LITE_APP_KEY: &str = "c24f74ca2820225badc01946dba4fdf7";
const LITE_APP_IV: &str = "adc01946dba4fdf7";

const API_HOST: &str = "http://login.user.kugou.com";
const LOGIN_ROUTER: &str = "login.user.kugou.com";
const LOGIN_RETRY_HOST: &str = "https://loginserviceretry.kugou.com";
const WEB_HOST: &str = "https://login-user.kugou.com";

fn try_decrypt_response(response: Value, aes_key: Option<&str>) -> Value {
    let Some(aes_key) = aes_key else {
        return response;
    };
    let secu = match response.get("secu_params").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return response,
    };
    let plain = crypto::aes_decrypt(secu, aes_key);
    let decrypted_json = match serde_json::from_str::<Value>(&plain) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(error = %e, "[login] 解密 secu_params 失败");
            return response;
        }
    };

    let mut root = response;
    if let (Some(root_obj), Some(dec_obj)) = (root.as_object_mut(), decrypted_json.as_object()) {
        for (k, v) in dec_obj {
            root_obj.insert(k.clone(), v.clone());
        }
    }
    root
}

pub async fn send_sms_code(
    client: &reqwest::Client,
    session: &KgSession,
    mobile: &str,
) -> AppResult<Value> {
    let body = json!({ "businessid": 5, "mobile": mobile, "plat": 3 });
    let req = KgRequest::get("/v7/send_mobile_code")
        .method(reqwest::Method::POST)
        .base_url(API_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn login_by_mobile(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
    mobile: &str,
    code: &str,
    userid: Option<&str>,
) -> AppResult<Value> {
    let date_ms = chrono::Utc::now().timestamp_millis();

    let t1_raw = format!("|{date_ms}");
    let t1_enc = crypto::aes_encrypt(&t1_raw, Some(LITE_T1_KEY), Some(LITE_T1_IV)).cipher_text;

    let t2_raw = format!(
        "{}|{T2_FIXED_HASH}|{}|{}|{date_ms}",
        session.install_guid, session.install_mac, session.install_dev
    );
    let t2_enc = crypto::aes_encrypt(&t2_raw, Some(LITE_T2_KEY), Some(LITE_T2_IV)).cipher_text;

    let aes_payload = json!({ "mobile": mobile, "code": code });
    let payload_enc = crypto::aes_encrypt(&aes_payload.to_string(), None, None);

    let pk_data = json!({ "clienttime_ms": date_ms, "key": payload_enc.temp_key });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();

    let masked = if mobile.chars().count() > 10 {
        let chars: Vec<char> = mobile.chars().collect();
        format!(
            "{}*****{}",
            chars[..2].iter().collect::<String>(),
            chars[10]
        )
    } else {
        mobile.to_string()
    };

    let mut body = json!({
        "plat": 1,
        "support_multi": 1,
        "t1": t1_enc,
        "t2": t2_enc,
        "clienttime_ms": date_ms,
        "mobile": masked,
        "key": signer::calc_login_key(date_ms),
        "pk": pk,
        "params": payload_enc.cipher_text,
        "dfid": "-",
        "dev": session.install_dev,
        "gitversion": "5f0b7c4"
    });

    let login_userid = userid.filter(|s| !s.is_empty()).unwrap_or(&session.userid);
    if !login_userid.is_empty() && login_userid != "0" {
        body["userid"] = json!(login_userid.parse::<i64>().unwrap_or(0));
    }

    let req = KgRequest::get("/v7/login_by_verifycode")
        .method(reqwest::Method::POST)
        .base_url(LOGIN_RETRY_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .custom_header("support-calm", "1")
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;
    let resp = try_decrypt_response(resp, Some(&payload_enc.temp_key));

    Ok(resp)
}

pub async fn get_qr_key(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v2/qrcode")
        .base_url(WEB_HOST)
        .param("appid", "1001")
        .param("clientver", "11040")
        .param("type", "1")
        .param("plat", "4")
        .param("srcappid", "2919")
        .param(
            "qrcode_txt",
            "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=3116&",
        )
        .signature_type(SignatureType::Web);
    transport::send(client, session, &req).await
}

pub async fn check_qr_status(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
    key: &str,
) -> AppResult<Value> {
    let req = KgRequest::get("/v2/get_userinfo_qrcode")
        .base_url(WEB_HOST)
        .param("plat", "4")
        .param("appid", "3116")
        .param("srcappid", "2919")
        .param("qrcode", key)
        .signature_type(SignatureType::Web);
    let resp = transport::send(client, session, &req).await?;

    Ok(resp)
}

pub async fn refresh_token(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
) -> AppResult<Value> {
    if session.token.is_empty() || session.userid == "0" {
        return Err(AppError::Unauthorized("本地无有效 Token，无法刷新".into()));
    }

    let date_ms = chrono::Utc::now().timestamp_millis();
    let clienttime_sec = date_ms / 1000;

    let t1_raw = if session.t1.is_empty() {
        format!("|{date_ms}")
    } else {
        format!("{}|{date_ms}", session.t1)
    };
    let t1_enc = crypto::aes_encrypt(&t1_raw, Some(LITE_T1_KEY), Some(LITE_T1_IV)).cipher_text;

    let t2_raw = format!(
        "{}|{T2_FIXED_HASH}|{}|{}|{date_ms}",
        session.install_guid, session.install_mac, session.install_dev
    );
    let t2_enc = crypto::aes_encrypt(&t2_raw, Some(LITE_T2_KEY), Some(LITE_T2_IV)).cipher_text;

    let p3_data = json!({ "clienttime": clienttime_sec, "token": session.token });
    let p3_enc = crypto::aes_encrypt(&p3_data.to_string(), Some(LITE_APP_KEY), Some(LITE_APP_IV))
        .cipher_text;

    let params_enc = crypto::aes_encrypt("{}", None, None);

    let pk_data = json!({ "clienttime_ms": date_ms, "key": params_enc.temp_key });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();

    let body = json!({
        "dfid": "-",
        "p3": p3_enc,
        "plat": 1,
        "t1": t1_enc,
        "t2": t2_enc,
        "t3": "MCwwLDAsMCwwLDAsMCwwLDA=",
        "pk": pk,
        "params": params_enc.cipher_text,
        "userid": session.userid,
        "clienttime_ms": date_ms,
        "dev": session.install_dev
    });

    let req = KgRequest::get("/v5/login_by_token")
        .method(reqwest::Method::POST)
        .base_url(API_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;
    let resp = try_decrypt_response(resp, Some(&params_enc.temp_key));

    Ok(resp)
}

pub async fn logout(client: &reqwest::Client, _session_key: &str, session: &KgSession) {
    let _ = (client, session);
}

// ===== 微信扫码登录（KuGouMusicApi login_wx_create/login_wx_check/login_openplat 移植） =====

// 酷狗内置微信开放平台凭据（同 KuGouMusicApi util/config.json 的 lite 对）。
// 本项目全链路模拟概念版 lite 客户端（LITE_* 密钥 / liteAppid=3116），而
// openplat 的 t1/t2 加密仅在 lite 分支发送，故微信凭据也取 lite 对。
// 标准版备选（isLite=false 分支）：appid wx79f2c4418704b4f8 / secret 4efcab88b700769e376e3f6087b8abc9。
const WX_APPID: &str = "wx72b795aca60ad321";
const WX_SECRET: &str = "33e486041e5e25729a4e3d2da7502f9a";

/// 微信域名直连 GET（共享 reqwest 连接池；不经 Kugou transport——
/// 微信接口不适用酷狗的签名/风控头注入）。响应必须是 JSON。
async fn wx_get_json(client: &reqwest::Client, url: &str) -> AppResult<Value> {
    let text = client
        .get(url)
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("微信请求发送失败: {e}")))?
        .text()
        .await
        .map_err(|e| AppError::Upstream(format!("微信响应读取失败: {e}")))?;
    serde_json::from_str::<Value>(&text)
        .map_err(|e| AppError::Upstream(format!("微信响应解析失败: {e}")))
}

/// 微信侧错误归一化：status=0 + 可读 msg，Dart 层据此抛 ApiException。
fn wx_err_json(resp: &Value, prefix: &str) -> Value {
    let detail = resp
        .get("errmsg")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| resp.to_string());
    json!({
        "status": 0,
        "errcode": resp.get("errcode").cloned().unwrap_or(json!(-1)),
        "msg": format!("{prefix}: {detail}"),
    })
}

/// 生成微信登录二维码（login_wx_create.js 三步链）：
/// client_credential token → sdk_ticket → SHA1 签名 → qrconnect 拿 uuid+二维码。
/// 二维码归一化为 data URI（qrcode_img），供 Dart 侧扫码表单直接渲染。
pub async fn wx_qr_create(client: &reqwest::Client) -> AppResult<Value> {
    // 1) access_token：全局共享凭证，多设备并发获取会互相顶替（微信有 5 分钟
    //    平滑期），偶发失败可直接重试。
    let token_json = wx_get_json(
        client,
        &format!(
            "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid={WX_APPID}&secret={WX_SECRET}"
        ),
    )
    .await?;
    let access_token = token_json
        .get("access_token")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if access_token.is_empty() {
        return Ok(wx_err_json(&token_json, "微信 access_token 获取失败"));
    }

    // 2) sdk_ticket（type=2）
    let ticket_json = wx_get_json(
        client,
        &format!(
            "https://api.weixin.qq.com/cgi-bin/ticket/getticket?type=2&access_token={access_token}"
        ),
    )
    .await?;
    if ticket_json.get("errcode").and_then(|v| v.as_i64()) != Some(0) {
        return Ok(wx_err_json(&ticket_json, "微信 sdk_ticket 获取失败"));
    }
    let ticket = ticket_json
        .get("ticket")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // 3) 签名（noncestr=md5(random)，SHA1 小写 hex，与 JS cryptoSha1 一致）
    let timestamp = chrono::Utc::now().timestamp_millis();
    let noncestr = crypto::md5_str(&crypto::random_string(16));
    let sign_src = format!(
        "appid={WX_APPID}&noncestr={noncestr}&sdk_ticket={ticket}&timestamp={timestamp}"
    );
    let signature = {
        use sha1::Digest;
        let mut hasher = sha1::Sha1::new();
        hasher.update(sign_src.as_bytes());
        hex::encode(hasher.finalize())
    };
    let connect_json = wx_get_json(
        client,
        &format!(
            "https://open.weixin.qq.com/connect/sdk/qrconnect?appid={WX_APPID}&noncestr={noncestr}&timestamp={timestamp}&scope=snsapi_userinfo&signature={signature}"
        ),
    )
    .await?;
    if connect_json.get("errcode").and_then(|v| v.as_i64()) != Some(0) {
        return Ok(wx_err_json(&connect_json, "微信二维码生成失败"));
    }
    let uuid = connect_json
        .get("uuid")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if uuid.is_empty() {
        return Ok(json!({ "status": 0, "errcode": -1, "msg": "微信二维码响应缺少 uuid" }));
    }

    // 二维码 base64 字段两版并存（KuGouMusicApi 透传 qrcode.qrcode /
    // E-cells 前端读 qrcode.qrcodebase64），统一补 data: 前缀成 data URI。
    let qrcode_b64 = connect_json
        .pointer("/qrcode/qrcodebase64")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            connect_json
                .pointer("/qrcode/qrcode")
                .and_then(|v| v.as_str())
        })
        .unwrap_or("");
    let qrcode_img = if qrcode_b64.starts_with("data:") {
        qrcode_b64.to_string()
    } else {
        format!("data:image/jpeg;base64,{qrcode_b64}")
    };

    Ok(json!({
        "status": 1,
        "errcode": 0,
        "uuid": uuid,
        "qrcode_img": qrcode_img,
        "qrcodeurl": format!("https://open.weixin.qq.com/connect/confirm?uuid={uuid}"),
    }))
}

/// 轮询微信扫码状态（login_wx_check.js：纯代理微信长轮询接口）。
/// 透传 wx_errcode（408 等待/404 已扫待确认/403 拒绝/405 成功带 wx_code/402 过期），
/// 状态语义由 Dart 侧解释；非 JSON 响应归一化为 -1（按等待处理）。
pub async fn wx_qr_check(client: &reqwest::Client, uuid: &str) -> AppResult<Value> {
    let url = format!(
        "https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid={uuid}"
    );
    let text = client
        .get(&url)
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("微信扫码状态请求失败: {e}")))?
        .text()
        .await
        .map_err(|e| AppError::Upstream(format!("微信扫码状态读取失败: {e}")))?;
    match serde_json::from_str::<Value>(&text) {
        Ok(v) => Ok(v),
        Err(_) => Ok(json!({ "wx_errcode": -1, "wx_code": "" })),
    }
}

/// 开放平台登录（login_openplat.js 移植，partnerid=36 微信专属）：
/// wx_code 换微信 access_token/openid → 酷狗 /v6/login_by_openplat 换酷狗会话。
/// 加密构造与 login_by_mobile 同构；差异：载荷 {access_token}、多 openid/
/// force_login/partnerid、无 key 字段（不需 calc_login_key）。
pub async fn login_by_openplat(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
    code: &str,
) -> AppResult<Value> {
    // 1) wx_code 单次有效：换微信 access_token + openid
    let wx_token_url = format!(
        "https://api.weixin.qq.com/sns/oauth2/access_token?appid={WX_APPID}&secret={WX_SECRET}&code={code}&grant_type=authorization_code"
    );
    let token_json = client
        .post(&wx_token_url)
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("微信授权请求发送失败: {e}")))?
        .json::<Value>()
        .await
        .map_err(|e| AppError::Upstream(format!("微信授权响应读取失败: {e}")))?;
    let wx_access_token = token_json
        .get("access_token")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let openid = token_json
        .get("openid")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if wx_access_token.is_empty() || openid.is_empty() {
        // 典型错误：40029 code 无效 / 40163 code 已被使用（此时须整段重新拉码）
        return Ok(wx_err_json(&token_json, "微信授权失败"));
    }

    // 2) t1/t2/pk 加密与 login_by_mobile 逐行同构
    let date_ms = chrono::Utc::now().timestamp_millis();
    let t1_raw = format!("|{date_ms}");
    let t1_enc = crypto::aes_encrypt(&t1_raw, Some(LITE_T1_KEY), Some(LITE_T1_IV)).cipher_text;
    let t2_raw = format!(
        "{}|{T2_FIXED_HASH}|{}|{}|{date_ms}",
        session.install_guid, session.install_mac, session.install_dev
    );
    let t2_enc = crypto::aes_encrypt(&t2_raw, Some(LITE_T2_KEY), Some(LITE_T2_IV)).cipher_text;
    let payload = json!({ "access_token": wx_access_token });
    let payload_enc = crypto::aes_encrypt(&payload.to_string(), None, None);
    let pk_data = json!({ "clienttime_ms": date_ms, "key": payload_enc.temp_key });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();

    let body = json!({
        "dev": session.install_dev,
        "force_login": 1,
        "partnerid": 36,
        "clienttime_ms": date_ms,
        "t1": t1_enc,
        "t2": t2_enc,
        "t3": "MCwwLDAsMCwwLDAsMCwwLDA=",
        "openid": openid,
        "params": payload_enc.cipher_text,
        "pk": pk,
    });

    // 3) 网关 + x-router（KuGouMusicApi useAxios 默认网关 + login.user 路由）
    let req = KgRequest::get("/v6/login_by_openplat")
        .method(reqwest::Method::POST)
        .base_url(config::DEFAULT_GATEWAY)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;
    // status=1 时解密 secu_params 得 token；api_response 已把 data 提升到根，
    // 与 login_by_mobile 相同，engine.persist_login / Dart LoginSession 均在根上取值。
    let resp = try_decrypt_response(resp, Some(&payload_enc.temp_key));
    Ok(resp)
}
