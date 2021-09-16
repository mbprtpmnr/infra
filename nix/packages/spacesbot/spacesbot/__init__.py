from nio import AsyncClient, Api, Response, JoinedRoomsError, JoinError, JoinResponse, RoomMessagesResponse, RoomReadMarkersResponse
from typing import Tuple, List, Dict, Optional, Union

from dataclasses import field, dataclass

import asyncio


class SpacesApi:
    @staticmethod
    def request_spaces(access_token: str, room_id: str) -> Tuple[str, str]:
        path = ["org.matrix.msc2946", "rooms", room_id, "spaces"]
        return "GET", Api._build_path(
            path, dict(access_token=access_token), base_path="/_matrix/client/unstable"
        )


@dataclass
class Room:
    room_id: str = field()
    avatar_url: Optional[str] = field()
    guest_can_join: bool = field()
    name: str = field()
    num_joined_members: int = field()
    topic: Optional[str] = field()
    world_readable: bool = field()
    join_rules: Optional[str] = field()
    room_type: Optional[str] = field()
    allowed_spaces: Optional[List[str]] = field()

    @classmethod
    def from_dict(cls, parsed_dict: Dict) -> "Room":
        return cls(
            room_id=parsed_dict["room_id"],
            avatar_url=parsed_dict.get("avatar_url"),
            guest_can_join=parsed_dict["guest_can_join"],
            name=parsed_dict["name"],
            num_joined_members=parsed_dict["num_joined_members"],
            topic=parsed_dict.get("topic"),
            world_readable=parsed_dict["world_readable"],
            join_rules=parsed_dict.get("join_rules"),
            room_type=parsed_dict.get("room_type"),
            allowed_spaces=parsed_dict.get("allowed_spaces"),
        )


@dataclass
class SpacesResponse(Response):
    rooms: List[Room] = field()
    events: List[Dict] = field()

    @classmethod
    def from_dict(cls, parsed_dict: Dict) -> "SpacesResponse":
        # validate_json(parsed_dict, )
        print(parsed_dict)

        return cls(
            rooms=[Room.from_dict(room) for room in parsed_dict["rooms"]],
            events=parsed_dict["events"],
        )


class SpacesBot:

    client: AsyncClient

    def __init__(self, homeserver_url: str, user: str, access_token: str, room_id):
        self.client = AsyncClient(homeserver_url)
        self.client.access_token = access_token
        self.client.user_id = user
        self.space_room_id = room_id

    async def run(self) -> None:
        await self.client.set_displayname("spacesbot - keeps a log of public NixOS channels")
        await self.client.set_presence("unavailable", "I am just a bot")

        await self.client.sync(timeout=30000)
        await self.join_space()

    async def join_space(self):
        joined_rooms = await self.client.joined_rooms()

        if isinstance(joined_rooms, JoinedRoomsError):
            print(joined_rooms)
            raise joined_rooms

        if self.space_room_id not in joined_rooms.rooms:
            await self.join_via(self.space_room_id)
            joined_rooms = await self.client.joined_rooms()

        additional_spaces = True
        while additional_spaces:
            additional_spaces = False
            response = await self.query_spaces(self.space_room_id)
            joined_rooms = await self.client.joined_rooms()
            for room in response.rooms:
                if room.room_id in joined_rooms.rooms:
                    continue
                if room.room_type == 'm.space':
                    await self.client.join_via(room.room_id)
                    additional_spaces = True
                    await asyncio.sleep(5)

        response = await self.query_spaces(self.space_room_id)
        joined_rooms = await self.client.joined_rooms()
        for room in response.rooms:
            if room.room_id not in joined_rooms.rooms:
                print("joining", room.room_id, room)
                response = await self.join_via(room.room_id)
                print(response)
                await asyncio.sleep(5)


        await self.mark_rooms_as_read()
        # Do not log this user out as otherwise the access token is invalid
        # await self.client.logout()

    async def query_spaces(self, room_id: str) -> SpacesResponse:
        method, path = SpacesApi.request_spaces(self.client.access_token, room_id)
        print(method, path)
        return await self.client._send(SpacesResponse, method, path)

    async def mark_rooms_as_read(self) -> None:
        next_batch = self.client.next_batch
        joined_rooms = await self.client.joined_rooms()
        if isinstance(joined_rooms, JoinedRoomsError):
            print(joined_rooms)
            raise joined_rooms

        for room in joined_rooms.rooms:
            print(f"Marking room {room} as read")
            response = await self.client.room_messages(room, next_batch, limit=1000)
            if not isinstance(response, RoomMessagesResponse):
                print(f'Unexpected room_messages response for {room}: {response}')
                continue

            last_event_id = None
            while response.chunk:
                await asyncio.sleep(0.5)
                # got a response with messages, try to go forward until we can't.
                try:
                    event_id = response.chunk[-1].event_id
                    print(f'last_event_id={event_id}')
                    if last_event_id == event_id:
                        break
                    last_event_id = event_id
                except AttributeError as e:
                    # the event doesn't seem to have an event_id attributek
                    print(f"Failed to get last_event_id from chunk: {response.chunk}")
                except IndexError:
                    # the chunk was empty after all?
                    pass

                response = await self.client.room_messages(room, response.end, limit=1000)
                if not isinstance(response, RoomMessagesResponse):
                    print(f'Unexpected room_messages response for {room}: {response}')
                    break

            if last_event_id:
                print(f"Latest known event_id for room {room} is {last_event_id}")
                response = await self.client.room_read_markers(room, fully_read_event=last_event_id, read_event=last_event_id)
                if not isinstance(response, RoomReadMarkersResponse):
                    print(f"Unexpected response to room_read_markers: {response}")
                    continue

                print(f"Set read marker for room {room}: {response}")
                await asyncio.sleep(5)


    async def join_via(self, room_id: str) -> Union[JoinResponse, JoinError]:
        via = room_id.split(':')[1]

        path = Api._build_path(['join', room_id], dict(access_token=self.client.access_token, server_name=via))
        return await self.client._send(JoinResponse, 'POST', path, Api.to_json({}))
