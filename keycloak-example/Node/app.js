const express = require('express');
const session = require('express-session');
const path = require('path')
const dotenv = require('dotenv')
const jwt = require('jsonwebtoken')
const bcrypt = require('bcryptjs')
const favicon = require('serve-favicon');
const https = require('https')
const fs = require('fs')
const bodyParser = require('body-parser');
const cookieParser = require('cookie-parser');
const passport = require('passport');
const saml = require('passport-saml');

const PORT = 3000;

dotenv.config({ path: './.env'})

const app = express();
const pv_key = fs.readFileSync('keycloakpoc.key.pem', 'utf8');
const pub_cert = fs.readFileSync('keycloakpoc.cert.pem', 'utf8');
const idp_cert = fs.readFileSync('idp-pub-key.pem', 'utf8');

/** SAML Configurations attributes
 * callbackurl : apps url for IDP to response post authetication
 * signout: apps url for IDP to notify app post signout
 * entrypoint: IDP url to redirect for authentication
 * entityId : Apps Id
 */
const samlConfig = {
    issuer: "poc-application",
    entityId: "Saml-SSO-App",
    callbackUrl: "https://app.keycloak.sequoiacombine.io:3000/login/callback",
    signOut: "https://app.keycloak.sequoiacombine.io:3000/signout/callback",
    entryPoint: "https://poc.keycloak.sequoiacombine.io/realms/combine/protocol/saml",
};

const publicDir = path.join(__dirname, './public')

passport.serializeUser(function (user, done) {
    //Serialize user, console.log if needed
    done(null, user);
});

passport.deserializeUser(function (user, done) {
    //Deserialize user, console.log if needed
    done(null, user);
});

// configure SAML strategy for SSO
const samlStrategy = new saml.Strategy({
    callbackUrl: samlConfig.callbackUrl,
    entryPoint: samlConfig.entryPoint,
    issuer: samlConfig.issuer,
    identifierFormat: null,
    decryptionPvk: pv_key,
    cert: [idp_cert, idp_cert],
    privateCert: fs.readFileSync('keycloakpoc.key.pem', 'utf8'),
    validateInResponseTo: true,
    disableRequestedAuthnContext: true,
}, (profile, done) => {
    console.log('passport.use() profile: %s \n', JSON.stringify(profile));
    return done(null, profile);
});

//initialize the express middleware
app.use(cookieParser());
app.use(bodyParser.urlencoded({ extended: false }))
app.use(bodyParser.json())
app.use(express.static(publicDir))

//configure session management
// Note: Always configure session before passport initialization & passport session, else error will be encounter
app.use(session({
    secret: 'secret',
    resave: false,
    saveUninitialized: true,
}));

passport.use('samlStrategy', samlStrategy);
app.use(passport.initialize({}));
app.use(passport.session({}));

app.set('view engine', 'hbs')

app.get("/", (req, res) => {
    res.render("index")
})

app.post("/", (req, res) => {
    res.render("index")
})

//login route
app.get('/login',
    (req, res, next) => {

        //login handler starts
        next();
    },
    passport.authenticate('samlStrategy'),
);

app.get("/login-success", (req, res) => {
    res.render("login-success")
})

//post login callback route
app.post("/login/callback",
    (req, res, next) => {

        //login callback starts
        next();
    },
    passport.authenticate('samlStrategy'),
    (req, res) => {

        //SSO response payload
        console.log("User info:",req.user);
        var userID = req.user.nameID;
        return res.render('login-success', {
            message: 'Welcome! You have successfully logged in. Username: ' + userID
        })
    }
);

//Run the https server
const server = https.createServer({
    'key': pv_key,
    'cert': pub_cert,
    'passphrase': {INSERT_KEYFILE_PASSWORD_HERE}
}, app).listen(PORT, () => {
    console.log('Listening on %d', server.address().port)
});