module:log('info', 'Starting visitors_component at %s', module.host);

local jid = require 'util.jid';
local iterators = require 'util.iterators';
local st = require 'util.stanza';
local util = module:require 'util';
local room_jid_match_rewrite = util.room_jid_match_rewrite;
local get_room_from_jid = util.get_room_from_jid;
local get_focus_occupant = util.get_focus_occupant;
local get_room_by_name_and_subdomain = util.get_room_by_name_and_subdomain;
local new_id = require 'util.id'.medium;

local muc_domain_prefix = module:get_option_string('muc_mapper_domain_prefix', 'conference');
local muc_domain_base = module:get_option_string('muc_mapper_domain_base');
if not muc_domain_base then
    module:log('warn', 'No muc_domain_base option set.');
    return;
end

local auto_allow_promotion = module:get_option_boolean("auto_allow_visitor_promotion", false);

-- This is a map to keep data for room and the jids that were allowed to join after visitor mode is enabled
-- automatically allowed or allowed by a moderator
local visitors_promotion_map = {};

local sent_iq_cache = require 'util.cache'.new(200);

-- listens for iq request for promotion and forward it to moderators in the meeting for approval
-- or auto-allow it if such the config is set enabling it
local function stanza_handler(event)
    local origin, stanza = event.origin, event.stanza;

    if stanza.name ~= 'iq' then
        return;
    end

    if stanza.attr.type == 'result' and sent_iq_cache:get(stanza.attr.id) then
        sent_iq_cache:set(stanza.attr.id, nil);
        return true;
    end

    if stanza.attr.type ~= 'set' then
        return; -- We do not want to reply to these, so leave.
    end

    local visitors_iq = event.stanza:get_child('visitors', 'jitsi:visitors');
    if not visitors_iq then
        return;
    end

    if origin.type ~= 's2sin' then
        module:log('warn', 'not from s2s session, ignore! %s', stanza);
        return true;
    end

    local room_jid = visitors_iq.attr.room;
    local room = get_room_from_jid(room_jid_match_rewrite(room_jid));

    if not room then
        log('warn', 'No room found %s', room_jid);
        return;
    end

    local request_promotion = visitors_iq:get_child('promotion-request');
    if not request_promotion then
        return;
    end

    -- respond with successful receiving the iq
    origin.send(st.iq({
        type = "result";
        from = stanza.attr.to;
        to = stanza.attr.from;
        id = stanza.attr.id
    }));

    -- TODO send iq to moderators (what about name? -> it will be coming from the token) or auto allow
    if not visitors_promotion_map[room.jid] and auto_allow_promotion then
        -- visitors is enabled
        visitors_promotion_map[room.jid] = {};
    end

    -- if visitors is enabled for the room
    if visitors_promotion_map[room.jid] then
        if auto_allow_promotion then
            --  we are in auto-allow mode, let's reply with accept
            -- we store where the request is coming from so we can send back the response
            local username = new_id():lower();
            visitors_promotion_map[room.jid][username] = {
                from = stanza.attr.from;
                jid = request_promotion.attr.jid;
                room = visitors_iq.attr.room;
            };

            local req_from = visitors_promotion_map[room.jid][username].from;
            local req_room = visitors_promotion_map[room.jid][username].room;
            local req_jid = visitors_promotion_map[room.jid][username].jid;
            local focus_occupant = get_focus_occupant(room);
            local focus_jid = focus_occupant and focus_occupant.bare_jid or nil;

            local iq_id = new_id();
            sent_iq_cache:set(iq_id, socket.gettime());

            module:send(st.iq({
                type='set',
                to = req_from,
                from = module.host,
                id = iq_id })
                          :tag('visitors', {
                xmlns='jitsi:visitors',
                room = string.gsub(req_room, muc_domain_base, req_from),
                focusjid = focus_jid })
                          :tag('promotion-response', {
                xmlns='jitsi:visitors',
                jid = req_jid,
                username = username ,
                allow = 'true' }):up());
            return true;
        end

        -- TODO send promotion request to all moderators
    end
end

module:hook("iq/host", stanza_handler, 10);

 --process a host module directly if loaded or hooks to wait for its load
function process_host_module(name, callback)
    local function process_host(host)
        if host == name then
            callback(module:context(host), host);
        end
    end

    if prosody.hosts[name] == nil then
        module:log('debug', 'No host/component found, will wait for it: %s', name)

        -- when a host or component is added
        prosody.events.add_handler('host-activated', process_host);
    else
        process_host(name);
    end
end

process_host_module(muc_domain_prefix..'.'..muc_domain_base, function(host_module, host)
    -- if visitor mode is started, then you are not allowed to join without request/response exchange of iqs -> deny access
    -- check list of allowed jids for the room
    host_module:hook('muc-occupant-pre-join', function (event)
        local room, stanza, origin = event.room, event.stanza, event.origin;

        -- we skip any checks when auto-allow is enabled
        if auto_allow_promotion then
            return;
        end

        if visitors_promotion_map[room.jid] then
            -- now let's check for jid
            if visitors_promotion_map[room.jid] and visitors_promotion_map[room.jid][jid.node(stanza.attr.from)] then
                -- allow join
                return;
            end

            origin.send(st.error_reply(stanza, 'cancel', 'not-allowed', 'Visitor needs to be allowed by a moderator'));
            return true;
        end

    end, 7); -- after muc_meeting_id, the logic for not joining before jicofo
    host_module:hook('muc-room-destroyed', function (event)
        visitors_promotion_map[event.room.jid] = nil;
    end);
end);

-- enable only in case of auto-allow is enabled
if auto_allow_promotion then
    prosody.events.add_handler("pre-jitsi-authentication", function(session)
        if not session.customusername or not session.jitsi_web_query_room then
            return nil;
        end

        local room = get_room_by_name_and_subdomain(session.jitsi_web_query_room, session.jitsi_web_query_prefix);
        if not room then
            return nil;
        end

        if visitors_promotion_map[room.jid] and visitors_promotion_map[room.jid][session.customusername] then
            -- user was previously allowed to join, let him use the requested jid
            return session.customusername;
        end
    end);
end
