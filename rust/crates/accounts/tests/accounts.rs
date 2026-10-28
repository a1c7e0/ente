#![cfg(test)]
#![cfg(feature = "museum")]

use ente_accounts::{
    AccountsClient, AccountsClientConfig, TwoFactorSetup,
    lifecycle::recover_two_factor,
    login::{LoginFlow, LoginStep},
    models::TwoFactorType,
    signup::Signup,
};
use ente_core::b64;
use ente_test_support::account_fixture::current_totp;
use ente_test_support::{HARDCODED_OTT, HARDCODED_OTT_EMAIL_SUFFIX, Museum, TestResult};
use uuid::Uuid;

#[test]
fn accounts() -> TestResult {
    Museum::run_async(run)
}

async fn run(endpoint: String) -> TestResult {
    let endpoint = &endpoint;
    let email = format!(
        "accounts-e2e-{}{HARDCODED_OTT_EMAIL_SUFFIX}",
        Uuid::new_v4()
    );
    let password = format!("Accounts-{}!", Uuid::new_v4().simple());
    let client = accounts_client(endpoint);
    client.send_otp(&email, "signup").await?;
    let response = client
        .verify_email(&email, HARDCODED_OTT, Some("testAccount"))
        .await?;
    let created = Signup::verified(email.clone(), response)?
        .prepare(&client, &password)
        .await?
        .finish(&client)
        .await?;
    let setup = TwoFactorSetup::start(
        &client,
        &created.secrets.master_key,
        &created.key_attributes,
    )
    .await?;
    setup
        .enable(&client, &current_totp(&setup.secret_code)?)
        .await?;

    let login_client = accounts_client(endpoint);
    let (mut flow, mut step) = LoginFlow::start(&login_client, email.clone()).await?;
    let login = loop {
        step = match step {
            LoginStep::EmailCode => flow.submit_code(&login_client, HARDCODED_OTT).await?,
            LoginStep::Password => flow.submit_password(&login_client, &password).await?,
            LoginStep::SecondFactor { totp: true, .. } => {
                flow.submit_code(&login_client, &current_totp(&setup.secret_code)?)
                    .await?
            }
            LoginStep::SecondFactor { .. } => panic!("expected authenticator verification"),
            LoginStep::Complete(account) => break account,
        };
    };
    assert_eq!(login.user_id, created.user_id);
    assert_eq!(login.secrets.master_key, created.secrets.master_key);
    assert_eq!(client.email().await.unwrap(), email);
    assert!(client.get_two_factor_status().await.unwrap());
    let recovery_client = accounts_client(endpoint);
    recovery_client.send_otp(&email, "login").await?;
    let pending = recovery_client
        .verify_email(&email, HARDCODED_OTT, None)
        .await?;
    let session = pending.get_two_factor_session_id().unwrap();
    let envelope = recovery_client
        .get_two_factor_recovery(session, TwoFactorType::Totp)
        .await?;
    let recovered = recover_two_factor(
        &recovery_client,
        TwoFactorType::Totp,
        session,
        &envelope,
        created.recovery_key.as_ref().unwrap(),
    )
    .await?;
    assert_eq!(recovered.id, created.user_id);
    let attributes = &recovered.key_attributes;
    let kek = ente_accounts::auth::derive_kek(
        &password,
        &attributes.kek_salt,
        attributes.mem_limit,
        attributes.ops_limit,
    )?;
    let secrets =
        ente_accounts::auth::decrypt_secrets(&kek, attributes, &recovered.encrypted_token)?;
    recovery_client.set_auth_token(Some(b64::encode_url_safe(&secrets.token)));
    assert_eq!(recovery_client.email().await?, email);
    assert!(!recovery_client.get_two_factor_status().await?);
    assert_eq!(
        secrets.master_key.as_bytes(),
        created.secrets.master_key.as_slice()
    );
    Ok(())
}

fn accounts_client(endpoint: &str) -> AccountsClient {
    AccountsClient::new(
        AccountsClientConfig::new("io.ente.photos")
            .with_origin(endpoint)
            .with_user_agent("ente-accounts-e2e"),
    )
    .unwrap()
}
